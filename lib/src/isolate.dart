import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:bip340/bip340.dart' as bip340;
import 'package:models/models.dart';
import 'package:purplebase/src/utils.dart';
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

  final pool = WebSocketPool(config);

  Database? db;
  try {
    if (config.databasePath != null) {
      final dirPath = path.join(Directory.current.path, config.databasePath);
      db = sqlite3.open(dirPath);
    } else {
      db = sqlite3.openInMemory();
    }
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

          final result = <Row>[];
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

          response = IsolateResponse(success: true, result: result.decoded());

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
          response = IsolateResponse(success: true, result: result.decoded());

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

  // Event massaging
  final (encodedEvents, tagsForId) = events
      // Filter events by verified
      .where((e) {
        return config.skipVerification ? true : _verifyEvent(e);
      })
      .encoded(keepSignatures: config.keepSignatures);

  final incomingIds = events.map((p) => p['id']).toList();

  final sql = '''
    SELECT id FROM events WHERE id IN (${incomingIds.map((_) => '?').join(', ')});
    INSERT OR REPLACE INTO events (id, pubkey, kind, created_at, blob) VALUES (:id, :pubkey, :kind, :created_at, :blob);
    INSERT OR REPLACE INTO event_tags (event_id, value, is_relay) VALUES (:event_id, :value, :is_relay);
  ''';
  // TODO: And FTS?
  final [existingPs, eventPs, tagsPs] = db.prepareMultiple(sql);

  final ids = <String>{};
  try {
    final existingIds =
        existingPs.select(incomingIds).map((e) => e['id']).toSet();

    db.execute('BEGIN');
    for (final event in encodedEvents) {
      // Remember encoded events properties start with a colon
      // TODO: Careful here, :id can be a replaceable now!
      final alreadySaved = existingIds.contains(event[':id']);
      final relayUrls = relaysForId[event[':id']] ?? {};

      if (!alreadySaved) {
        eventPs.executeWith(StatementParameters.named(event));
        if (db.updatedRows > 0) {
          ids.add(event[':id']);
        }

        for (final List tag in tagsForId[event[':id']]!) {
          // TODO: Allow specific tags to be indexed
          if (tag.length < 2 || tag[0].toString().length > 1) continue;
          tagsPs.executeWith(
            StatementParameters.named({
              ':event_id': event[':id'],
              ':value': '${tag[0]}:${tag[1]}',
              ':is_relay': false,
            }),
          );
        }

        for (final relayUrl in relayUrls) {
          tagsPs.executeWith(
            StatementParameters.named({
              ':event_id': event[':id'],
              ':value': relayUrl,
              ':is_relay': true,
            }),
          );
        }
      } else {
        for (final relayUrl in relayUrls) {
          tagsPs.executeWith(
            StatementParameters.named({
              ':event_id': event[':id'],
              ':value': relayUrl,
              ':is_relay': true,
            }),
          );
        }
        if (db.updatedRows > 0) {
          // If rows were updated then value changed, so notifier gets the ID
          ids.add(event[':id']);
        }
      }
    }
    db.execute('COMMIT');
  } catch (e) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    existingPs.dispose();
    eventPs.dispose();
  }

  return ids;
}

// TODO: Faster validation via ffi?
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

// TODO: Fulltext search should be optional via config
final setUpSql = '''
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA mmap_size = ${1 * 1024 * 1024 * 1024};
  PRAGMA page_size = 4096;
  PRAGMA cache_size = -20000;

  CREATE TABLE IF NOT EXISTS events(
    id TEXT NOT NULL PRIMARY KEY,
    pubkey TEXT NOT NULL,
    kind INTEGER NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    blob BLOB NOT NULL
  ) WITHOUT ROWID;

  CREATE INDEX IF NOT EXISTS pubkey_idx ON events(pubkey);
  CREATE INDEX IF NOT EXISTS kind_idx ON events(kind);
  CREATE INDEX IF NOT EXISTS created_at_idx ON events(created_at);

  CREATE TABLE IF NOT EXISTS event_tags (
    event_id  TEXT    NOT NULL,
    value     TEXT    NOT NULL,
    is_relay  INTEGER NOT NULL                -- 0 = no, 1 = yes
              CHECK (is_relay IN (0,1)) 
              DEFAULT 0,

    PRIMARY KEY (event_id, value),            -- composite PK
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
  ) WITHOUT ROWID;

  CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
    text,
    content='events',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 1',
    columnsize=0,
    detail=none
  );

  CREATE INDEX IF NOT EXISTS value_idx ON event_tags(value);
    ''';

// TODO: Add triggers, necessary for updates (replaceables) and deletions

final tearDownSql = '''
  DROP TABLE IF EXISTS events;
  DROP TABLE IF EXISTS event_tags;
  DROP TABLE IF EXISTS events_fts;
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
  final RemoteSource source;
  RemoteQueryIsolateOperation({required this.req, required this.source});
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
