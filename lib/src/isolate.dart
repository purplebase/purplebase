import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:bip340/bip340.dart' as bip340;
import 'package:collection/collection.dart';
import 'package:models/models.dart';
import 'package:purplebase/src/websocket_pool.dart';
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

  final pool = WebSocketPool();

  Database? db;
  try {
    final dirPath = path.join(Directory.current.path, config.databasePath);
    // print('Opening database at $dirPath [database isolate]');
    db = sqlite3.open(dirPath);
    db.execute(setUpSql);
  } catch (e) {
    print('Error opening database: $e');
  }

  // Listen for messages from websocket pool
  closeFn = pool.addListener((response) {
    if (response case EventRelayResponse(:final events, :final relaysForIds)) {
      final ids = _save(db!, events, relaysForIds, config);
      mainSendPort.send(ids);
    }
  });

  // Listen for messages from main isolate (UI)
  sub = receivePort.listen((message) async {
    if (message case (
      final IsolateOperation operation,
      final SendPort replyPort,
    )) {
      IsolateResponse response;

      switch (operation) {
        // LOCAL STORAGE

        case LocalQueryIsolateOperation(:final queries):
          final sql = queries.map((q) => q.$1).join(';\n');

          final result = [];
          final statements = db!.prepareMultiple(sql);

          try {
            for (final statement in statements) {
              final i = statements.indexOf(statement);
              final params = queries[i].$2;
              result.addAll(
                statement.selectWith(StatementParameters.named(params)),
              );
            }
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
          } finally {
            for (final statement in statements) {
              statement.dispose();
            }
          }

          response = IsolateResponse(success: true, result: result.toList());

        case LocalSaveIsolateOperation(:final events):
          final ids = _save(db!, events, {}, config);
          response = IsolateResponse(success: true, result: ids);

        case LocalClearIsolateOperation():
          // Drop all tables and set up again, deleting tables was problematic

          try {
            db!.execute(tearDownSql);
            db.execute(setUpSql);
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
            return;
          }

          response = IsolateResponse(success: true);

        // REMOTE

        case RemoteQueryIsolateOperation(:final req, :final source):
          final relayUrls = config.getRelays(source: source);
          final result = await pool.query(req, relayUrls: relayUrls);
          // No saving here, events are saved in the callback as query also emits
          response = IsolateResponse(success: true, result: result);

        case RemotePublishIsolateOperation(:final events, :final source):
          final relayUrls = config.getRelays(source: source, useDefault: true);
          final result = await pool.publish(events, relayUrls: relayUrls);
          response = IsolateResponse(success: true, result: result);

        case RemoteCancelIsolateOperation(:final req):
          pool.unsubscribe(req);
          response = IsolateResponse(success: true);

        // ISOLATE

        case CloseIsolateOperation():
          db?.dispose();
          pool.dispose();
          closeFn?.call();
          response = IsolateResponse(success: true);
          Future.microtask(() => sub?.cancel());
      }

      replyPort.send(response);
    }
  });
}

Set<String> _save(
  Database db,
  Set<Map<String, dynamic>> events,
  Map<String, Set<String>> relaysForId,
  StorageConfiguration config,
) {
  if (events.isEmpty) {
    return {};
  }

  // Filter events by verified
  final verifiedEvents =
      events
          .where((m) => config.skipVerification ? true : _verifyEvent(m))
          .toList();

  final incomingIds = verifiedEvents.map((p) => p['id']).toList();

  final sql = '''
    SELECT id FROM events WHERE id IN (${incomingIds.map((_) => '?').join(', ')});
    INSERT OR REPLACE INTO events (id, content, created_at, pubkey, kind, tags, relays, sig) VALUES (:id, :content, :created_at, :pubkey, :kind, :tags, :relays, :sig);
    UPDATE events SET relays = ? WHERE id = ? AND relays != ?;
  ''';
  final [existingPs, eventPs, relayUpdatePs] = db.prepareMultiple(sql);

  final ids = <String>{};
  try {
    db.execute('BEGIN');
    final existingIds =
        existingPs.select(incomingIds).map((e) => e['id']).toSet();

    for (final event in verifiedEvents) {
      final alreadySaved = existingIds.contains(event['id']);
      final sortedRelaysString = jsonEncode(
        relaysForId.containsKey(event['id'])
            ? relaysForId[event['id']]!.sorted()
            : [],
      );

      if (!alreadySaved) {
        final map = {
          for (final e in event.entries)
            // Prefix leading ':'
            ':${e.key}': switch (e.key) {
              'tags' => jsonEncode(e.value),
              _ => e.value,
            },
          ':relays': sortedRelaysString,
        };

        eventPs.executeWith(StatementParameters.named(map));
        if (db.updatedRows > 0) {
          ids.add(map[':id']);
        }
      } else {
        // If it was already saved, update relays
        if (sortedRelaysString.isNotEmpty) {
          relayUpdatePs.execute([
            sortedRelaysString,
            event['id'],
            sortedRelaysString,
          ]);
          if (db.updatedRows > 0) {
            // If rows were updated then value changed, so send ID to notifier
            ids.add(event['id']);
          }
        }
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

final setUpSql = '''
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA mmap_size = ${1 * 1024 * 1024 * 1024};
  PRAGMA page_size = 4096;
  PRAGMA cache_size = -20000;

  CREATE TABLE IF NOT EXISTS events(
    id TEXT PRIMARY KEY,
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
    ''';

final tearDownSql = '''
  DROP TRIGGER IF EXISTS events_ad;
  DROP TRIGGER IF EXISTS events_au;
  DROP TRIGGER IF EXISTS events_ai;
  DROP TABLE IF EXISTS events_fts;
  DROP TABLE IF EXISTS events;
  DROP TABLE IF EXISTS requests;
''';

//

sealed class IsolateOperation {}

final class LocalQueryIsolateOperation extends IsolateOperation {
  // Each pair contains (SQL statement with n `?` placeholders, n params)
  final List<(String, Map<String, dynamic>)> queries;

  LocalQueryIsolateOperation(this.queries);
}

final class LocalSaveIsolateOperation extends IsolateOperation {
  final Set<Map<String, dynamic>> events;
  LocalSaveIsolateOperation({required this.events});
}

final class RemotePublishIsolateOperation extends IsolateOperation {
  final List<Map<String, dynamic>> events;
  final RemoteSource source;

  RemotePublishIsolateOperation({required this.events, required this.source});
}

final class RemoteQueryIsolateOperation extends IsolateOperation {
  final Request req;
  final RemoteSource? source;
  RemoteQueryIsolateOperation({required this.req, this.source});
}

final class RemoteCancelIsolateOperation extends IsolateOperation {
  final Request req;
  RemoteCancelIsolateOperation({required this.req});
}

final class LocalClearIsolateOperation extends IsolateOperation {}

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
