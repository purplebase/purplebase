import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
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

  WebSocketPool? pool;
  StreamSubscription? _sub;
  StreamSubscription? _streamSub;
  bool Function(Map<String, dynamic> event)? _isEventVerified;
  final _closeFns = <String, void Function()>{};
  final _resultsOnEose = <(String, String), List<Map<String, dynamic>>>{};

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

    pool = WebSocketPool({'wss://relay.damus.io'});

    _sub = pool!.stream.listen((record) {
      final (relayUrl, data) = record;
      final [type, subscriptionId, ...rest] = jsonDecode(data) as List;

      try {
        switch (type) {
          case 'EVENT':
            final Map<String, dynamic> map = rest.first;
            // If collecting events for EOSE, do not attempt to verify here
            if (_resultsOnEose.containsKey((relayUrl, subscriptionId))) {
              _resultsOnEose[(relayUrl, subscriptionId)]!.add(map);
              return;
            }

            final alreadyVerified = _isEventVerified?.call(map) ?? false;
            if (alreadyVerified || _verifyEvent(map)) {
              // state = EventRelayMessage(
              //   relayUrl: relayUrl,
              //   event: map,
              //   subscriptionId: subscriptionId,
              // );

              final event = Event.getConstructorForKind(
                map['kind'],
              )?.call(map, ref);
              save({event}.cast());
            }
            break;
          case 'NOTICE':
          // if (_errorRegex.hasMatch(subscriptionId)) {
          //   // state = ErrorRelayMessage(
          //   //     relayUrl: relayUrl,
          //   //     subscriptionId: null,
          //   //     error: subscriptionId);
          //   state = RelayError(
          //     [...?state.models],
          //     message: 'error',
          //     subscriptionId: subscriptionId,
          //   );
          // }
          case 'CLOSED':
          // state = ErrorRelayMessage(
          //     relayUrl: relayUrl,
          //     subscriptionId: subscriptionId,
          //     error: rest.join(', '));
          // state = RelayError(
          //   [...?state.models],
          //   message: rest.join(', '),
          //   subscriptionId: subscriptionId,
          // );
          case 'EOSE':
            // if (_resultsOnEose.containsKey((relayUrl, subscriptionId))) {
            //   final incomingEvents =
            //       _resultsOnEose.remove((relayUrl, subscriptionId))!;
            //   _verifyEventsAsync(
            //     incomingEvents,
            //     isEventVerified: _isEventVerified,
            //   ).then((events) {
            //     // TODO: Implement EoseWithEvents
            //     // state = EoseWithEventsRelayMessage(
            //     //   relayUrl: relayUrl,
            //     //   events: events,
            //     //   subscriptionId: subscriptionId,
            //     // );
            //   });
            // } else {
            //   // state = EoseRelayMessage(
            //   //   relayUrl: relayUrl,
            //   //   subscriptionId: subscriptionId,
            //   // );
            // }
            break;
          case 'OK':
            // TODO: Implement publish
            // state = PublishedEventRelayMessage(
            //   relayUrl: relayUrl,
            //   subscriptionId: subscriptionId,
            //   accepted: rest.first as bool,
            //   message: rest.lastOrNull?.toString(),
            // );
            break;
        }
      } catch (err) {
        // state = ErrorRelayMessage(
        //     relayUrl: relayUrl, subscriptionId: null, error: err.toString());
        // state = RelayError(
        //   [...?state.models],
        //   message: err.toString(),
        //   subscriptionId: subscriptionId,
        // );
        _sub?.cancel();
        _streamSub?.cancel();
        _closeFns[subscriptionId]?.call();
        rethrow;
      }
    });

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
      'INSERT OR IGNORE INTO events (id, content, created_at, pubkey, kind, tags, sig) VALUES (:id, :content, :created_at, :pubkey, :kind, :tags, :sig) RETURNING id;',
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
  /// Ideally to be used for must-have sync interfaces such relationships
  /// upon widget first load, and tests. Prefer [query] otherwise.
  List<Event> querySync(
    RequestFilter req, {
    bool applyLimit =
        true, // Keep parameter for override compatibility, but not used directly
    Set<String>? onIds,
  }) {
    // Note: applyLimit parameter is not used here as the limit comes from req.limit
    final (sql, params) = req.toSQL(onIds: onIds);
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
  Future<List<Event<Event>>> query(
    RequestFilter req, {
    bool applyLimit = true,
    Set<String>? onIds,
  }) async {
    _ensureInitialized();
    final (sql, params) = req.toSQL(onIds: onIds);
    final result = await _isolateManager.query(sql, [params]);
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

  @override
  Future<void> send(RequestFilter req) async {
    // First caching layer: ids
    if (req.ids.isNotEmpty) {
      final (idsSql, idsParams) = RequestFilter(
        ids: req.ids,
      ).toSQL(returnIds: true);
      final storedIds = await _isolateManager.query(idsSql, [idsParams]);
      // Modify req to only query for ids that are not in local storage
      req = req.copyWith(
        ids: req.ids.difference(storedIds.map((e) => e['id']).toSet()),
      );
    }
    print(req.toMap());

    pool!.send(jsonEncode(["REQ", req.subscriptionId, req.toMap()]));
  }

  @override
  Future<void> dispose() async {
    for (final closeFn in _closeFns.values) {
      closeFn.call();
    }
    await pool!.close();
    _sub?.cancel();
    _streamSub?.cancel();
    if (mounted) {
      super.dispose();
    }
  }

  // Previous query methods

  // Future<List<Map<String, dynamic>>> queryRaw(RequestFilter req) async {
  //   final completer = Completer<List<Map<String, dynamic>>>();

  //   final relayUrls = pool!.relayUrls;
  //   final allEvents = <Map<String, dynamic>>[];
  //   final eoses = <String, bool>{for (final r in relayUrls) r: false};

  //   _closeFns[req.subscriptionId] = addListener((message) {
  //     if (message.subscriptionId != req.subscriptionId) return;
  //     switch (message) {
  //       case EoseWithEventsRelayMessage(:final events, :final relayUrl):
  //         eoses[relayUrl!] = true;
  //         for (final event in events) {
  //           if (!allEvents.any((e) => e['id'] == event['id'])) {
  //             allEvents.add(event);
  //           }
  //         }
  //         // If there are at least as much EOSEs as connected relays, we're good
  //         final enoughEoses = eoses.values.where((v) => v).length >=
  //             pool!.connectedRelayUrls.length;
  //         if (enoughEoses && !completer.isCompleted) {
  //           final allEventsSorted = allEvents.sortedByCompare(
  //               (m) => m['created_at'] as int, (a, b) => b.compareTo(a));
  //           completer.complete(allEventsSorted);
  //           scheduleMicrotask(() {
  //             _closeFns[req.subscriptionId]?.call();
  //           });
  //         }
  //         break;
  //       case ErrorRelayMessage(:final error):
  //         completer.completeError(Exception(error));
  //         break;
  //       default:
  //     }
  //   }, fireImmediately: false);

  //   send(req);
  //   for (final relayUrl in relayUrls) {
  //     _resultsOnEose[(relayUrl, req.subscriptionId)] = [];
  //   }

  //   return completer.future;
  // }

  // Future<List<E>> query<E extends Event<E>>(
  //     {Set<String>? ids,
  //     Set<String>? authors,
  //     Map<String, dynamic>? tags,
  //     String? search,
  //     DateTime? since,
  //     DateTime? until,
  //     int? limit,
  //     Iterable<String>? relayUrls}) async {
  //   final req = RequestFilter(
  //       kinds: {Event.types[E.toString()]!.kind},
  //       ids: ids ?? {},
  //       authors: authors ?? {},
  //       tags: tags,
  //       search: search,
  //       since: since,
  //       until: until,
  //       limit: limit);

  //   final result = await queryRaw(req);
  //   return result.map(Event.getConstructor<E>()!.call).toList();
  // }

  // Verification

  // ignore: unused_element
  static Future<List<Map<String, dynamic>>> _verifyEventsAsync(
    List<Map<String, dynamic>> incomingEvents, {
    bool Function(Map<String, dynamic> event)? isEventVerified,
  }) async {
    if (incomingEvents.isEmpty) return [];

    final unverifiedEvents =
        isEventVerified != null
            ? incomingEvents.whereNot(isEventVerified).toList()
            : incomingEvents;

    if (unverifiedEvents.isNotEmpty) {
      final notVerifiedEvents = await Isolate.run(
        () => unverifiedEvents.whereNot(_verifyEvent).toList(),
      );
      for (final nve in notVerifiedEvents) {
        incomingEvents.remove(nve);
      }
    }
    return incomingEvents;
  }

  static bool _verifyEvent(Map<String, dynamic> map) {
    // TODO RESTORE
    // return bip340.verify(map['pubkey'], map['id'], map['sig']);
    return true;
  }
}

extension _RFX on RequestFilter {
  (String, Map<String, dynamic>) toSQL({
    Set<String>? onIds,
    bool returnIds = false,
  }) {
    final params = <String, dynamic>{};
    final whereClauses = <String>[];
    int paramIndex = 0; // Counter for unique parameter names

    // Helper function to generate unique parameter names
    String nextParamName(String base) => ':${base}_${paramIndex++}';

    // Handle IDs
    final allIds = {...ids, ...?onIds};
    if (allIds.isNotEmpty) {
      final idParams = <String>[];
      for (final id in allIds) {
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
    var sql = 'SELECT ${returnIds ? 'id' : '*'} FROM events';

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
