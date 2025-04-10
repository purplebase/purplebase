import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:bip340/bip340.dart' as bip340;
import 'package:collection/collection.dart';
import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as path;

void isolateEntryPoint(List args) {
  final [SendPort mainSendPort, StorageConfiguration config] = args;

  // Create a receive port for incoming messages
  final receivePort = ReceivePort();

  // Send this isolate's SendPort back to the main isolate
  mainSendPort.send(receivePort.sendPort);

  void Function()? closeFn;
  StreamSubscription? sub;

  final container = ProviderContainer();
  final pool = WebSocketPool(container.read(refProvider));

  // Open the database
  // TODO: Have a DB version somewhere (for future migrations)
  Database? db;
  try {
    final dirPath = path.join(Directory.current.path, config.databasePath);
    print('Opening database at $dirPath [database isolate]');
    db = sqlite3.open(dirPath);

    db.execute('''
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      PRAGMA mmap_size = ${1 * 1024 * 1024 * 1024};
      PRAGMA page_size = 4096;
      PRAGMA cache_size = -20000;
      
      CREATE TABLE IF NOT EXISTS events(
        id TEXT PRIMARY KEY,
        lid TEXT, -- latest ID of a replaceable
        pubkey TEXT NOT NULL,
        kind INTEGER NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        content TEXT NOT NULL,
        tags TEXT NOT NULL,
        relays TEXT,
        sig TEXT
      );

      CREATE INDEX IF NOT EXISTS pubkey_idx ON events(pubkey);
      CREATE INDEX IF NOT EXISTS kind_idx ON events(kind);
      CREATE INDEX IF NOT EXISTS created_at_idx ON events(created_at);

      -- FTS5 virtual table for tags and search
      CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
        id UNINDEXED,
        tags,
        relays,
        content='events',
        content_rowid='rowid'
      );

      CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
        INSERT INTO events_fts (rowid, tags, relays)
          VALUES (
            NEW.rowid,
            (SELECT GROUP_CONCAT(json_extract(value, '\$[0]') || ':' || json_extract(value, '\$[1]'), ' ')
              FROM json_each(NEW.tags)
              WHERE LENGTH(value ->> '\$[0]') = 1),
            (SELECT GROUP_CONCAT(value, ' ') FROM json_each(NEW.relays))
          );
      END;

      CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
        UPDATE events_fts 
        SET 
          tags = (SELECT GROUP_CONCAT(json_extract(value, '\$[0]') || ':' || json_extract(value, '\$[1]'), ' ')
                  FROM json_each(NEW.tags)
                  WHERE LENGTH(value ->> '\$[0]') = 1),
          relays = (SELECT GROUP_CONCAT(value, ' ') FROM json_each(NEW.relays))
        WHERE rowid = NEW.rowid;
      END;

      CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
        DELETE FROM events_fts WHERE rowid = OLD.rowid;
      END;

      CREATE TABLE IF NOT EXISTS requests(
        request TEXT,
        until INTEGER
      );

      CREATE INDEX IF NOT EXISTS request_idx ON requests(request);
    ''');
  } catch (e) {
    print('Error opening database: $e');
  }

  closeFn = pool.addListener((args) {
    if (args case (final events, final responseMetadata)) {
      _save(db!, events, responseMetadata.relayUrls, config);

      final ids = events.map((e) => e['id']).cast<String>().toSet();
      mainSendPort.send((ids, responseMetadata));
    }
  });

  sub = receivePort.listen((message) {
    if (message case (
      final IsolateOperation operation,
      final SendPort replyPort,
    )) {
      IsolateResponse response;
      PreparedStatement? statement;

      try {
        switch (operation) {
          case QueryIsolateOperation(:final sql, :final params):
            statement = db!.prepare(sql);
            final result = statement.selectWith(
              StatementParameters.named(params),
            );
            response = IsolateResponse(success: true, result: result.toList());

          case SaveIsolateOperation(:final events, :final relayGroup):
            final relayUrls = config.getRelays(relayGroup);
            final ids = _save(db!, events, relayUrls, config);
            response = IsolateResponse(success: true, result: ids);

          case ClearIsolateOperation():
            statement = db!.prepare(
              'DELETE FROM events; DELETE FROM events_fts;',
            );
            statement.execute();
            response = IsolateResponse(success: true);

          case SendEventIsolateOperation(:final req, :final relayGroup):
            final relayUrls = config.getRelays(relayGroup);
            pool.send(req, relayUrls: relayUrls);
            response = IsolateResponse(success: true);

          case CloseIsolateOperation():
            // TODO: Check this closes correctly and is restartable
            db?.dispose();
            pool.dispose();
            closeFn?.call();
            response = IsolateResponse(success: true);
            Future.microtask(() {
              sub?.cancel();
            });
        }
      } catch (e) {
        response = IsolateResponse(success: false, error: e.toString());
      } finally {
        statement?.dispose();
      }

      replyPort.send(response);
    }
  });
}

Set<String> _save(
  Database db,
  List<Map<String, dynamic>> parameters,
  Set<String> relayUrls,
  StorageConfiguration config,
) {
  final keepSig = config.keepSignatures;

  // Filter events by verified
  final params =
      parameters
          .where((m) => config.skipVerification ? true : _verifyEvent(m))
          .toList();

  if (params.isEmpty) {
    return {};
  }

  final sortedRelays =
      relayUrls.isNotEmpty ? jsonEncode(relayUrls.sorted()) : null;
  print('saving for relays: $sortedRelays');

  final nonReplaceableIncomingIds =
      params
          // If param map is bigger than a single entry it means it's a full event
          .where((p) => p.length > 1 && !Event.isReplaceable(p))
          .map((p) => p['id'])
          .toList();

  final sql = '''
    SELECT id FROM events WHERE id IN (${nonReplaceableIncomingIds.map((_) => '?').join(', ')});
    INSERT OR REPLACE INTO events (id, lid, content, created_at, pubkey, kind, tags, relays${keepSig ? ', sig' : ''}) VALUES (:id, :lid, :content, :created_at, :pubkey, :kind, :tags, :relays${keepSig ? ', :sig' : ''});
    UPDATE events SET relays = ? WHERE id = ? AND relays != ?;
  ''';
  final [existingPs, eventPs, relayUpdatePs] = db.prepareMultiple(sql);

  final ids = <String>{};
  try {
    db.execute('BEGIN');
    final existingNonReplaceableIds =
        existingPs
            .select(nonReplaceableIncomingIds)
            .map((e) => e['id'])
            .toSet();

    for (final param in params) {
      final isFullEvent = param.length > 1;
      final alreadySaved = existingNonReplaceableIds.contains(param['id']);

      if (isFullEvent && !alreadySaved) {
        final map = {
          for (final e in param.entries)
            // Prefix leading ':'
            ':${e.key}': switch (e.key) {
              'id' => Event.addressableId(param),
              'tags' => jsonEncode(e.value),
              _ => e.value,
            },
          ':lid': Event.isReplaceable(param) ? param['id'] : null,
          ':relays': sortedRelays,
        };

        if (!keepSig) {
          map.remove(':sig');
        }

        final id = map[':id'];

        print('inserting $map');
        eventPs.executeWith(StatementParameters.named(map));
        if (db.updatedRows > 0) {
          ids.add(id);
        }
      } else {
        // TODO: This will fail with replaceable events, can't recreate the addressable ID
        // If it is not a full event (i.e. just a {'id': id})
        // or it was already saved, update relays
        // if (sortedRelays != null) {
        //   relayUpdatePs.execute([sortedRelays, param['id'], sortedRelays]);
        //   if (db.updatedRows > 0) {
        //     // If rows were updated then value changed, so send ID to notifier
        //     ids.add(param['id']);
        //   }
        // }
      }
    }
    db.execute('COMMIT');
  } catch (e) {
    db.execute('ROLLBACK');
    print(e);
  } finally {
    existingPs.dispose();
    eventPs.dispose();
    relayUpdatePs.dispose();
  }

  return ids;
}

bool _verifyEvent(Map<String, dynamic> map) {
  bool verified = false;
  if (map['sig'] != null && map['sig'] != '') {
    verified = bip340.verify(map['pubkey'], map['id'], map['sig']);
    if (!verified) {
      print(
        '[purplebase] WARNING: Event ${map['id']} has an invalid signature',
      );
    }
  }
  return verified;
}

//

sealed class IsolateOperation {}

final class QueryIsolateOperation extends IsolateOperation {
  final String sql;
  final Map<String, dynamic> params;

  QueryIsolateOperation({required this.sql, required this.params});
}

final class SaveIsolateOperation extends IsolateOperation {
  final List<Map<String, dynamic>> events;
  final String? relayGroup;

  SaveIsolateOperation({required this.events, this.relayGroup});
}

final class SendEventIsolateOperation extends IsolateOperation {
  final RequestFilter req;
  final String? relayGroup;

  SendEventIsolateOperation({required this.req, this.relayGroup});
}

final class ClearIsolateOperation extends IsolateOperation {}

final class CloseIsolateOperation extends IsolateOperation {}

/// Response from isolate
class IsolateResponse {
  final bool success;
  final dynamic result;
  final String? error;

  IsolateResponse({required this.success, this.result, this.error});
}

class IsolateException implements Exception {
  final String? message;
  IsolateException([this.message]);

  @override
  String toString() => 'IsolateException: $message';
}

final refProvider = Provider((ref) => ref);
