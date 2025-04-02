import 'dart:async';
import 'dart:isolate';
import 'package:sqlite3/sqlite3.dart';

/// Message types for isolate communication
enum SqliteMessageType { execute, query, insert, close }

/// Message structure for isolate communication
class SqliteMessage {
  final SqliteMessageType type;
  final String sql;
  final List<Map<String, Object?>> parameters;
  final SendPort replyPort;

  SqliteMessage({
    required this.type,
    required this.sql,
    this.parameters = const [],
    required this.replyPort,
  });
}

/// Response from isolate
class SqliteResponse {
  final bool success;
  final dynamic result;
  final String? error;

  SqliteResponse({required this.success, this.result, this.error});
}

/// Manages a long-running isolate for SQLite operations
class SqliteIsolateManager {
  final String dbPath;
  Isolate? _isolate;
  SendPort? _sendPort;
  final Completer<void> _initCompleter = Completer<void>();

  SqliteIsolateManager(this.dbPath);

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
  Future<SqliteResponse> _sendMessage(SqliteMessage message) async {
    await _initCompleter.future;

    final responsePort = ReceivePort();
    final msg = SqliteMessage(
      type: message.type,
      sql: message.sql,
      parameters: message.parameters,
      replyPort: responsePort.sendPort,
    );

    _sendPort!.send(msg);

    return await responsePort.first as SqliteResponse;
  }

  /// Execute a SQL statement without returning results
  Future<void> execute(
    String sql, [
    List<Map<String, Object?>> parameters = const [],
  ]) async {
    final response = await _sendMessage(
      SqliteMessage(
        type: SqliteMessageType.execute,
        sql: sql,
        parameters: parameters,
        replyPort: const _DummySendPort(),
      ),
    );

    if (!response.success) {
      throw DatabaseException(response.error ?? 'Unknown database error');
    }
  }

  /// Execute a query and return the results
  Future<List<Map<String, dynamic>>> query(
    String sql, [
    List<Map<String, Object?>> parameters = const [],
  ]) async {
    final response = await _sendMessage(
      SqliteMessage(
        type: SqliteMessageType.query,
        sql: sql,
        parameters: parameters,
        replyPort: const _DummySendPort(),
      ),
    );

    if (!response.success) {
      throw DatabaseException(response.error ?? 'Unknown database error');
    }

    return response.result as List<Map<String, dynamic>>;
  }

  /// Insert data and return the last inserted row ID
  Future<Set<String>> insert(
    String sql, [
    List<Map<String, Object?>> parameters = const [],
  ]) async {
    final response = await _sendMessage(
      SqliteMessage(
        type: SqliteMessageType.insert,
        sql: sql,
        parameters: parameters,
        replyPort: const _DummySendPort(),
      ),
    );

    if (!response.success) {
      throw DatabaseException(response.error ?? 'Unknown database error');
    }

    return response.result as Set<String>;
  }

  /// Close the isolate and database connection
  Future<void> close() async {
    if (_isolate == null) return;

    await _sendMessage(
      SqliteMessage(
        type: SqliteMessageType.close,
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
      PRAGMA mmap_size = 30000000;
      PRAGMA page_size = 4096;
      PRAGMA cache_size = -4000;
      
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
    ''');
  } catch (e) {
    print('Error opening database: $e');
  }

  // Listen for messages
  receivePort.listen((dynamic message) {
    if (message is! SqliteMessage) return;

    final replyPort = message.replyPort;
    SqliteResponse response;

    try {
      switch (message.type) {
        case SqliteMessageType.execute:
          final stmt = db!.prepare(message.sql);
          stmt.execute(message.parameters);
          stmt.dispose();
          response = SqliteResponse(success: true);
          break;

        case SqliteMessageType.query:
          final stmt = db!.prepare(message.sql);
          final result = stmt.select(message.parameters);
          final columnNames = result.columnNames;
          final rows =
              result.map((row) {
                final map = <String, dynamic>{};
                for (var i = 0; i < columnNames.length; i++) {
                  map[columnNames[i]] = row[i];
                }
                return map;
              }).toList();
          stmt.dispose();
          response = SqliteResponse(success: true, result: rows);
          break;

        case SqliteMessageType.insert:
          final statement = db!.prepare(message.sql);
          final ids = <String>{};
          db.execute('BEGIN');
          for (final params in message.parameters) {
            // print('inserting $params');
            // select because it's an INSERT with a RETURNING
            final rows = statement.selectWith(
              StatementParameters.named(params),
            );
            if (rows.isNotEmpty) {
              ids.add(rows.first['id']);
            }
          }
          db.execute('COMMIT');
          statement.dispose();
          response = SqliteResponse(success: true, result: ids);
          break;

        case SqliteMessageType.close:
          db?.dispose();
          response = SqliteResponse(success: true);
          break;
      }
    } catch (e) {
      response = SqliteResponse(success: false, error: e.toString());
    }

    replyPort.send(response);
  });
}
