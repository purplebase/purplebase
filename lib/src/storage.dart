import 'dart:async';
import 'dart:convert';

import 'package:models/models.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/pool.dart';
import 'package:purplebase/src/request.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

class PurplebaseStorageNotifier extends StorageNotifier {
  final Ref ref;

  static PurplebaseStorageNotifier? _instance; // singleton

  factory PurplebaseStorageNotifier(Ref ref) {
    return _instance ??= PurplebaseStorageNotifier._internal(ref);
  }

  PurplebaseStorageNotifier._internal(this.ref);

  late final IsolateManager _isolateManager;
  late final Database db;
  var _initialized = false;
  var applyLimit = true;

  WebSocketPool? pool;
  StreamSubscription? _sub;
  StreamSubscription? _streamSub;
  final _closeFns = <String, void Function()>{};

  /// Initialize the storage with a database path
  @override
  Future<void> initialize(StorageConfiguration config) async {
    await super.initialize(config);

    if (_initialized) return;

    db = sqlite3.open(config.databasePath!);

    // Configure sqlite: 1 GB memory mapped
    db.execute('''
      PRAGMA mmap_size = ${1 * 1024 * 1024 * 1024};
      PRAGMA page_size = 4096;
      PRAGMA cache_size = -20000;
      ''');

    _isolateManager = IsolateManager(config.databasePath!);
    await _isolateManager.initialize();

    pool = WebSocketPool(ref);

    _sub = pool!.stream.listen((record) async {
      if (record == null) return;
      final (req, events) = record;
      await _saveInternal(events);
    });

    _initialized = true;
  }

  Future<void> _saveInternal(List<Map<String, dynamic>> maps) async {
    if (maps.isEmpty) return;

    _ensureInitialized();

    // Check for existing IDs in database and remove
    // Reuse logic on RequestFilter#toSQL() for this
    // Exclude nulls, we have no idea what is coming in
    final requestedIds = maps.map((m) => m['id']?.toString()).nonNulls.toSet();
    final (idsSql, idsParams) = RequestFilter(
      ids: requestedIds,
    ).toSQL(returnIds: true);

    final savedIds = await _isolateManager.query(idsSql, [idsParams]);
    final idsToSave = requestedIds.difference(
      savedIds.map((e) => e['id']!).toSet(),
    );

    final mapsToSave = maps.where((m) => idsToSave.contains(m['id'])).toList();

    final ids = await _isolateManager.save(mapsToSave, config);
    state = StorageSignal(ids);
  }

  @override
  Future<void> save(Set<Event> events) async {
    final maps = events.map((e) => e.toMap()).toList();
    await _saveInternal(maps);
  }

  @override
  Future<void> clear([RequestFilter? req]) async {
    _ensureInitialized();
    await _isolateManager.clear();
  }

  @override
  List<Event> querySync(
    RequestFilter req, {
    bool applyLimit = true,
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
  Future<void> send(RequestFilter req, {Set<String>? relayUrls}) async {
    pool!.send(req, relayUrls: relayUrls);
  }

  @override
  Future<void> dispose() async {
    for (final closeFn in _closeFns.values) {
      closeFn.call();
    }
    pool!.dispose();
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
}

class PurplebaseConfiguration {
  final Duration idleTimeout;
  final Duration streamingBufferWindow;
  PurplebaseConfiguration({
    this.idleTimeout = const Duration(minutes: 5),
    this.streamingBufferWindow = const Duration(seconds: 2),
  });
}

final purplebaseConfigurationProvider = Provider(
  (_) => PurplebaseConfiguration(),
);

// TODO: Have a DB version somewhere (for future migrations)
