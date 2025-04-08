import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'package:bip340/bip340.dart' as bip340;
import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

void isolateEntryPoint(List args) {
  final [SendPort mainSendPort, StorageConfiguration config] = args;

  // Create a receive port for incoming messages
  final receivePort = ReceivePort();

  // Send this isolate's SendPort back to the main isolate
  mainSendPort.send(receivePort.sendPort);

  void Function()? closeFn;

  final container = ProviderContainer();
  final pool = WebSocketPool(container.read(refProvider));

  // Open the database
  // TODO: Have a DB version somewhere (for future migrations)
  Database? db;
  try {
    db = sqlite3.open(config.databasePath);

    // TODO: How to handle replaceable events? (FTS5 rows can't be updated), test
    db.execute('''
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      
      CREATE TABLE IF NOT EXISTS events(
        id TEXT NOT NULL,
        pubkey TEXT NOT NULL,
        kind INTEGER NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        content TEXT,
        tags TEXT,
        sig TEXT
      );

      CREATE UNIQUE INDEX IF NOT EXISTS id_idx ON events(id);
      CREATE INDEX IF NOT EXISTS pubkey_idx ON events(pubkey);
      CREATE INDEX IF NOT EXISTS kind_idx ON events(kind);
      CREATE INDEX IF NOT EXISTS created_at_idx ON events(created_at);

      -- FTS5 virtual table for tags and search
      CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
        id UNINDEXED,  -- Reference to main table
        tags,          -- Space-separated tags
        search         -- Optional for other
      );

      CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
        INSERT INTO events_fts (id, tags)
          SELECT new.id, GROUP_CONCAT(json_extract(value, '\$[0]') || ':' || json_extract(value, '\$[1]'), ' ')
            FROM json_each(new.tags)
            WHERE LENGTH(value ->> '\$[0]') = 1;
      END;

      CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
        DELETE FROM events_fts WHERE id = OLD.id;
      END;

      CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
        DELETE FROM events_fts WHERE id = OLD.id;
        INSERT INTO events_fts(id, tags) VALUES (NEW.id, NEW.tags);
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

  // TODO: close too
  receivePort.listen((message) {
    if (message is! IsolateMessage) return;

    final replyPort = message.replyPort;
    IsolateResponse response;

    try {
      switch (message.type) {
        case IsolateOperationType.query:
          final statement = db!.prepare(message.sql!);
          final result = statement.selectWith(
            StatementParameters.named(message.parameters.first),
          );
          statement.dispose();
          response = IsolateResponse(success: true, result: result.toList());
          break;

        case IsolateOperationType.save:
          final ids = _save(db!, message.parameters, {}, message.config!);
          response = IsolateResponse(success: true, result: ids);
          break;

        case IsolateOperationType.clear:
          final statement = db!.prepare(
            'DELETE FROM events; DELETE FROM events_fts;',
          );
          statement.execute(message.parameters);
          statement.dispose();
          response = IsolateResponse(success: true);
          break;

        case IsolateOperationType.send:
          final (req, relayUrls) = message.sendParameters!;
          pool.send(req, relayUrls: relayUrls);
          response = IsolateResponse(success: true);
          break;

        case IsolateOperationType.close:
          db?.dispose();
          pool.dispose();
          closeFn?.call();
          response = IsolateResponse(success: true);
          break;
      }
    } catch (e) {
      response = IsolateResponse(success: false, error: e.toString());
    }

    replyPort.send(response);
  });
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

  // TODO: How about id in replaceable events?
  final sql =
      'INSERT OR IGNORE INTO events (id, content, created_at, pubkey, kind, tags${keepSig ? ', sig' : ''}) VALUES (:id, :content, :created_at, :pubkey, :kind, :tags${keepSig ? ', :sig' : ''}) RETURNING id;';
  final statement = db.prepare(sql);

  final sqlFts = '''UPDATE events_fts SET tags = tags || ' ' || ?''';
  final statementFts = db.prepare(sqlFts);

  final ids = <String>{};

  db.execute('BEGIN');
  for (final p in params) {
    final map = {
      for (final e in p.entries)
        // Prefix leading ':' and convert tags to JSON
        ':${e.key}': (e.value is List ? jsonEncode(e.value) : e.value),
    };

    if (!keepSig) {
      map.remove(':sig');
    }

    // Use selectWith because it's an INSERT with a RETURNING
    final rows = statement.selectWith(StatementParameters.named(map));
    if (rows.isNotEmpty) {
      final id = rows.first['id'];
      ids.add(id);
      // Add relays where it's been seen
      if (relayUrls.isNotEmpty) {
        statementFts.execute([
          map['id'],
          relayUrls.map((r) => '^r:$r').join(' '),
        ]);
      }
    }
  }
  db.execute('COMMIT');

  statement.dispose();

  return ids;
}

/// Message types for isolate communication
enum IsolateOperationType { clear, query, save, close, send }

/// Message structure for isolate communication
class IsolateMessage {
  final IsolateOperationType type;
  final String? sql;
  final List<Map<String, dynamic>> parameters;
  final StorageConfiguration? config;
  final (RequestFilter, Set<String>?)? sendParameters;
  final SendPort replyPort;

  IsolateMessage({
    required this.type,
    this.sql,
    this.parameters = const [],
    this.config,
    this.sendParameters,
    this.replyPort = const DummySendPort(),
  });
}

/// Response from isolate
class IsolateResponse {
  final bool success;
  final dynamic result;
  final String? error;

  IsolateResponse({required this.success, this.result, this.error});
}

/// Dummy SendPort used as a placeholder
class DummySendPort implements SendPort {
  const DummySendPort();

  @override
  void send(Object? message) {}
}

class IsolateException implements Exception {
  final String message;
  IsolateException(this.message);

  @override
  String toString() => 'IsolateException: $message';
}

final refProvider = Provider((ref) => ref);
