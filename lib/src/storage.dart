import 'dart:convert';

import 'package:models/models.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

class PurplebaseStorageNotifier extends StorageNotifier {
  final Ref ref;

  // Create singleton
  static PurplebaseStorageNotifier? _instance;

  factory PurplebaseStorageNotifier(Ref ref) {
    return _instance ??= PurplebaseStorageNotifier._internal(ref);
  }

  PurplebaseStorageNotifier._internal(this.ref);

  late final SqliteIsolateManager _isolateManager;
  late final Database db;
  var _initialized = false;
  var applyLimit = true;

  /// Initialize the storage with a database path
  @override
  Future<void> initialize(Config config) async {
    if (_initialized) return;

    _isolateManager = SqliteIsolateManager(config.databasePath!);
    await _isolateManager.initialize();

    db = sqlite3.open(config.databasePath!);

    // TODO: Check settings are OK on read side
    // final z = db.select('''
    //   PRAGMA page_size;
    //   PRAGMA  = -4000;
    //   cache_size
    //   ''');
    // print(z.first);

    //     final z = db.select('''SELECT
    //     value,
    //     json_extract(value, '\$[0]') AS tag_name,
    //     LENGTH(json_extract(value, '\$[0]', '\$')) AS extracted_length,
    //     LENGTH(value ->> '\$[0]') AS value_length
    // FROM json_each('[["a", "one"], ["foo", "bar"]]');''');
    //     print(z);

    _initialized = true;
  }

  @override
  Future<void> save(Set<Event> events) async {
    _ensureInitialized();
    if (events.isEmpty) return;
    final maps = [
      for (final event in events)
        {
          for (final e in event.toMap().entries)
            ':${e.key}':
                (e.value is List ? jsonEncode(e.value) : e.value) as Object?,
        },
    ];
    final ids = await _isolateManager.insert(
      'INSERT INTO events (id, content, created_at, pubkey, kind, tags, sig) VALUES (:id, :content, :created_at, :pubkey, :kind, :tags, :sig) RETURNING id;',
      maps,
    );
    state = StorageSignal(ids);
  }

  @override
  Future<void> clear([RequestFilter? req]) async {
    _ensureInitialized();
    await _isolateManager.execute('DELETE FROM events');
    await _isolateManager.execute('DELETE FROM events_fts');
  }

  @override
  List<Event> query(
    RequestFilter req, {
    bool applyLimit =
        true, // Keep parameter for override compatibility, but not used directly
    Set<String>? onIds,
  }) {
    // Note: applyLimit parameter is not used here as the limit comes from req.limit
    final (sql, params) = req.toSQL();
    final statement = db.prepare(sql);
    final result = statement.selectWith(
      StatementParameters.named(params),
    ); // params
    statement.dispose();
    final events = result.map(
      (row) => {
        'id': row['id'],
        'pubkey': row['pubkey'],
        'kind': row['kind'],
        'created_at': row['created_at'],
        'content': row['content'],
        'sig': row['sig'],
        'tags': jsonDecode(row['tags']),
      },
    );

    return events
        .map((e) => Event.getConstructorForKind(e['kind'])!.call(e, ref))
        .toList()
        .cast();
  }

  @override
  Future<List<Event<Event>>> queryAsync(
    RequestFilter req, {
    bool applyLimit = true,
    Set<String>? onIds,
  }) async {
    _ensureInitialized();
    // TODO: Query on isolate
    return [];
  }

  /// Close the database connection
  @override
  Future<void> close() async {
    if (!_initialized) return;
    await _isolateManager.close();
    _initialized = false;
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('Storage not initialized. Call initialize() first.');
    }
  }
}

class PurplebaseRequestNotifier extends RequestNotifier {
  PurplebaseRequestNotifier(super.ref, super.req);

  @override
  void send(RequestFilter req) {
    // TODO: implement send
  }
}

extension _RFX on RequestFilter {
  (String, Map<String, dynamic>) toSQL() {
    final params = <String, dynamic>{};
    final whereClauses = <String>[];
    int paramIndex = 0; // Counter for unique parameter names

    // Helper function to generate unique parameter names
    String nextParamName(String base) => ':${base}_${paramIndex++}';

    // Handle IDs
    if (ids.isNotEmpty) {
      final idParams = <String>[];
      for (final id in ids) {
        final paramName = nextParamName('id');
        idParams.add(paramName);
        // Add to params with the leading ':'
        params[paramName] = id;
      }
      whereClauses.add('id IN (${idParams.join(', ')})');
    }

    // Handle Kinds
    if (kinds.isNotEmpty) {
      final kindParams = <String>[];
      for (final kind in kinds) {
        final paramName = nextParamName('kind');
        kindParams.add(paramName);
        params[paramName] = kind;
      }
      whereClauses.add('kind IN (${kindParams.join(', ')})');
    }

    // Handle Authors (pubkeys)
    if (authors.isNotEmpty) {
      final authorParams = <String>[];
      for (final author in authors) {
        final paramName = nextParamName('author');
        authorParams.add(paramName);
        params[paramName] = author;
      }
      whereClauses.add('pubkey IN (${authorParams.join(', ')})');
    }

    // Handle Tags (using FTS)
    if (tags.isNotEmpty) {
      // Join groups with space (implicit AND in standard FTS query syntax)
      final ftsQuery = [
        for (final e in tags.entries)
          for (final v in e.value) '"${e.key}:$v"',
      ].join(' ');
      final tagsParamName = nextParamName('tags');
      whereClauses.add(
        'id IN (SELECT id FROM events_fts WHERE tags MATCH $tagsParamName)',
      );
      params[tagsParamName] = ftsQuery;
    }

    // Handle Search (using FTS on content)
    if (search != null && search!.isNotEmpty) {
      final searchParamName = nextParamName('search');
      whereClauses.add(
        'id IN (SELECT id FROM events_fts WHERE search MATCH $searchParamName)',
      );
      params[searchParamName] = search!;
    }

    // Handle Since (created_at > since)
    if (since != null) {
      final sinceParamName = nextParamName('since');
      whereClauses.add('created_at > $sinceParamName');
      // Convert DateTime to Unix timestamp (seconds)
      params[sinceParamName] = since!.millisecondsSinceEpoch ~/ 1000;
    }

    // Handle Until (created_at < until)
    if (until != null) {
      final untilParamName = nextParamName('until');
      whereClauses.add('created_at < $untilParamName');
      // Convert DateTime to Unix timestamp (seconds)
      params[untilParamName] = until!.millisecondsSinceEpoch ~/ 1000;
    }

    // --- Construct Final Query ---
    var sql = 'SELECT * FROM events';

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    // Add ordering (descending by creation time is standard for Nostr)
    sql += ' ORDER BY created_at DESC';

    // Handle Limit
    if (limit != null && limit! > 0) {
      final limitParamName = nextParamName('limit');
      sql += ' LIMIT $limitParamName';
      params[limitParamName] = limit!;
    }

    return (sql, params);
  }
}

// TODO: Have a DB version somewhere (for future migrations)
