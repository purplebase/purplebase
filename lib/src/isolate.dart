import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:bip340/bip340.dart' as bip340;
import 'package:models/models.dart';
import 'package:sqlite3/sqlite3.dart';

class IsolateManager {
  final String dbPath;
  Isolate? _isolate;
  SendPort? _sendPort;
  final Completer<void> _initCompleter = Completer<void>();

  IsolateManager(this.dbPath);

  /// Initialize the SQLite isolate
  Future<void> initialize() async {
    if (_isolate != null) return _initCompleter.future;

    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_sqliteIsolateEntryPoint, [
      receivePort.sendPort,
      dbPath,
    ]);

    _sendPort = await receivePort.first as SendPort;
    _initCompleter.complete();
    return _initCompleter.future;
  }

  /// Send a message to the isolate and get a response
  Future<IsolateResponse> _sendMessage(IsolateMessage message) async {
    await _initCompleter.future;

    final responsePort = ReceivePort();
    final msg = IsolateMessage(
      type: message.type,
      sql: message.sql,
      parameters: message.parameters,
      replyPort: responsePort.sendPort,
    );

    _sendPort!.send(msg);

    return await responsePort.first as IsolateResponse;
  }

  /// Execute a query and return the results
  Future<List<Map<String, dynamic>>> query(
    String sql, [
    List<Map<String, dynamic>> parameters = const [],
  ]) async {
    final response = await _sendMessage(
      IsolateMessage(
        type: IsolateOperationType.query,
        sql: sql,
        parameters: parameters,
      ),
    );

    if (!response.success) {
      throw DatabaseException(response.error ?? 'Unknown database error');
    }

    return response.result as List<Map<String, dynamic>>;
  }

  /// Insert data and return the last inserted row ID
  Future<Set<String>> save(
    List<Map<String, dynamic>> events,
    StorageConfiguration config,
  ) async {
    final response = await _sendMessage(
      IsolateMessage(
        type: IsolateOperationType.save,
        parameters: events,
        config: config,
      ),
    );

    if (!response.success) {
      throw DatabaseException(response.error ?? 'Unknown database error');
    }

    return response.result as Set<String>;
  }

  /// Clear the database
  Future<void> clear() async {
    final response = await _sendMessage(
      IsolateMessage(type: IsolateOperationType.clear, parameters: []),
    );

    if (!response.success) {
      throw DatabaseException(response.error ?? 'Unknown database error');
    }
  }

  /// Close the isolate and database connection
  Future<void> close() async {
    if (_isolate == null) return;

    await _sendMessage(
      IsolateMessage(
        type: IsolateOperationType.close,
        sql: '',
        replyPort: const _DummySendPort(),
      ),
    );

    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
  }
}

/// Dummy SendPort used as a placeholder
class _DummySendPort implements SendPort {
  const _DummySendPort();

  @override
  void send(Object? message) {}
}

/// Exception class for database errors
class DatabaseException implements Exception {
  final String message;
  DatabaseException(this.message);

  @override
  String toString() => 'DatabaseException: $message';
}

/// Entry point for the SQLite isolate
void _sqliteIsolateEntryPoint(List<dynamic> args) {
  final SendPort mainSendPort = args[0] as SendPort;
  final String dbPath = args[1] as String;

  // Create a receive port for incoming messages
  final receivePort = ReceivePort();

  // Send the port back to the main isolate
  mainSendPort.send(receivePort.sendPort);

  // Open the database
  Database? db;
  try {
    db = sqlite3.open(dbPath);

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

  bool verifyEvent(Map<String, dynamic> map) {
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

  // Listen for messages
  receivePort.listen((dynamic message) {
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
          // skipVerify comes as last of param list (if present), check and remove
          var skipVerify =
              message.parameters.lastOrNull?.containsKey('skipVerify') ?? false;
          if (skipVerify) {
            message.parameters.removeLast();
          }

          // Check if first param has sig, and prepare query (all or none should have sig)
          final hasSig =
              message.parameters.firstOrNull?.containsKey('sig') ?? false;

          if (!hasSig) {
            skipVerify = true;
          }

          // Filter events by verified
          final params =
              message.parameters
                  .where((m) => skipVerify ? true : verifyEvent(m))
                  .toList();

          if (params.isEmpty) {
            response = IsolateResponse(success: true, result: <String>{});
            break;
          }

          final sql =
              'INSERT OR IGNORE INTO events (id, content, created_at, pubkey, kind, tags${hasSig ? ', sig' : ''}) VALUES (:id, :content, :created_at, :pubkey, :kind, :tags${hasSig ? ', :sig' : ''}) RETURNING id;';
          final statement = db!.prepare(sql);

          final ids = <String>{};

          db.execute('BEGIN');
          for (final p in params) {
            final map = {
              for (final e in p.entries)
                // Prefix leading : , convert tags to JSON
                ':${e.key}': (e.value is List ? jsonEncode(e.value) : e.value),
            };

            // Use selectWith because it's an INSERT with a RETURNING
            final rows = statement.selectWith(StatementParameters.named(map));
            if (rows.isNotEmpty) {
              ids.add(rows.first['id']);
            }
          }
          db.execute('COMMIT');

          statement.dispose();

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

        case IsolateOperationType.close:
          db?.dispose();
          response = IsolateResponse(success: true);
          break;
      }
    } catch (e) {
      response = IsolateResponse(success: false, error: e.toString());
    }

    replyPort.send(response);
  });
}

/// Message types for isolate communication
enum IsolateOperationType { clear, query, save, close }

/// Message structure for isolate communication
class IsolateMessage {
  final IsolateOperationType type;
  final String? sql;
  final List<Map<String, dynamic>> parameters;
  final StorageConfiguration? config;
  final SendPort replyPort;

  IsolateMessage({
    required this.type,
    this.sql,
    this.parameters = const [],
    this.config,
    this.replyPort = const _DummySendPort(),
  });
}

/// Response from isolate
class IsolateResponse {
  final bool success;
  final dynamic result;
  final String? error;

  IsolateResponse({required this.success, this.result, this.error});
}
