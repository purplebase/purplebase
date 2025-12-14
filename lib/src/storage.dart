import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/utils.dart';
import 'package:sqlite3/sqlite3.dart';

class PurplebaseStorageNotifier extends StorageNotifier {
  PurplebaseStorageNotifier(super.ref);

  Database? db;
  Isolate? _isolate;
  SendPort? _sendPort;
  Completer<void>? _initCompleter;
  StreamSubscription? sub;
  Timer? _heartbeatTimer;

  /// In-memory cache for author+kind queries: "kind:author" -> lastFetchedAt
  final Map<String, DateTime> _authorKindCache = {};

  /// Initialize the storage with a configuration
  @override
  Future<void> initialize(StorageConfiguration config) async {
    if (isInitialized) return;

    await super.initialize(config);

    _initCompleter = Completer();

    if (config.databasePath != null) {
      final dirPath = path.join(Directory.current.path, config.databasePath!);
      db = sqlite3.open(dirPath);
    } else {
      db = sqlite3.openInMemory();
    }

    // Configure sqlite: 512 MB memory mapped
    db!.execute('''
      PRAGMA mmap_size = ${512 * 1024 * 1024};
      PRAGMA page_size = 4096;
      PRAGMA cache_size = -20000;
      ''');

    final verifier = ref.read(verifierProvider);

    // Initialize isolate
    if (_isolate != null) return _initCompleter!.future;

    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(isolateEntryPoint, [
      receivePort.sendPort,
      config,
      verifier,
    ]);

    sub = receivePort.listen((message) {
      switch (message) {
        case SendPort() when _sendPort == null:
          _sendPort = message;
          _initCompleter!.complete();
        case QueryResultMessage(:final request, :final savedIds)
            when savedIds.isNotEmpty:
          state = InternalStorageData(updatedIds: savedIds, req: request);
        case PoolStateMessage poolStateMessage:
          ref.read(poolStateProvider.notifier).emit(poolStateMessage.poolState);
      }
    });

    await _initCompleter!.future;
    isInitialized = true;

    // Start heartbeat to background isolate for health checks
    // Main isolate timers are reliable even after system sleep
    _startHeartbeat();
  }

  /// Start heartbeat to trigger health checks in background isolate
  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(PoolConstants.healthCheckInterval, (_) {
      _sendPort?.send(HeartbeatMessage(DateTime.now()));
    });
  }

  /// Force immediate reconnection on all disconnected relays.
  ///
  /// Call this when your app resumes from background to detect and recover
  /// from stale connections caused by system sleep or network changes.
  /// This resets backoff timers and attempts immediate reconnection.
  ///
  /// Example (Flutter):
  /// ```dart
  /// @override
  /// void didChangeAppLifecycleState(AppLifecycleState state) {
  ///   if (state == AppLifecycleState.resumed) {
  ///     ref.read(storageNotifierProvider.notifier).ensureConnected();
  ///   }
  /// }
  /// ```
  void ensureConnected() {
    if (!isInitialized) return;

    // Send heartbeat with forceReconnect to trigger ensureConnected in pool
    _sendPort?.send(HeartbeatMessage(DateTime.now(), forceReconnect: true));
  }

  /// Public save method
  /// (framework calls _save internally in isolate)
  @override
  Future<bool> save(Set<Model<dynamic>> events) async {
    if (events.isEmpty) return true;

    final maps = events.map((e) => e.toMap()).toSet();

    final response = await _sendMessage(
      LocalSaveIsolateOperation(events: maps),
    );

    if (!response.success) {
      state = StorageError(
        state.models,
        exception: IsolateException(response.error),
      );
      return false;
    }

    final result = response.result as Set<String>;
    if (result.isNotEmpty) {
      state = InternalStorageData(updatedIds: result, req: null);
    }

    return true;
  }

  /// Publish
  @override
  Future<PublishResponse> publish(
    Set<Model<dynamic>> events, {
    RemoteSource source = const RemoteSource(),
  }) async {
    if (events.isEmpty && source == LocalSource()) {
      return PublishResponse();
    }

    final maps = events.map((e) => e.toMap()).toList();

    final relayUrls = await resolveRelays(source.relays);
    source = source.copyWith(relays: relayUrls);
    final response = await _sendMessage(
      RemotePublishIsolateOperation(events: maps, source: source),
    );

    if (!response.success) {
      throw IsolateException(response.error);
    }

    return (response.result as PublishRelayResponse).wrapped;
  }

  @override
  Future<void> clear([Request? req]) async {
    final response = await _sendMessage(LocalClearIsolateOperation());

    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  @override
  List<E> querySync<E extends Model<dynamic>>(
    Request<E> req, {
    Set<String>? onIds,
  }) {
    // Check if the database has been disposed
    if (db == null) {
      throw IsolateException('Storage has been disposed');
    }

    final events = <Map<String, dynamic>>[];

    final tuples = req.filters.map((f) => f.toSQL()).toList();
    final statements = db!.prepareMultiple(tuples.map((t) => t.$1).join(';\n'));
    try {
      for (final statement in statements) {
        final i = statements.indexOf(statement);
        final result = statement.selectWith(
          StatementParameters.named(tuples[i].$2),
        );
        events.addAll(result.decoded());
      }
    } finally {
      for (final statement in statements) {
        statement.dispose();
      }
    }

    return events
        .map((e) => Model.getConstructorForKind(e['kind'])!.call(e, ref))
        .toList()
        .cast();
  }

  @override
  Future<List<E>> query<E extends Model<dynamic>>(
    Request<E> req, {
    Source? source,
    Set<String>? onIds,
    String? subscriptionPrefix,
  }) async {
    source ??= config.defaultQuerySource;
    
    print('[query] Called for type ${E.toString()}');
    print('[query] Source type: ${source.runtimeType}');
    print('[query] Filters count: ${req.filters.length}');
    for (final f in req.filters) {
      print('[query]   Filter: kinds=${f.kinds}, authors=${f.authors.length} authors');
    }

    if (req.filters.isEmpty) return [];

    if (source case RemoteSource()) {
      print('[query] Original source.relays: ${source.relays}');
      final relayUrls = await resolveRelays(source.relays);
      print('[query] Resolved relayUrls: $relayUrls');
      source = source.copyWith(relays: relayUrls);
      
      print('[query] Source is RemoteSource');
      print('[query] source is LocalAndRemoteSource: ${source is LocalAndRemoteSource}');
      if (source is LocalAndRemoteSource) {
        print('[query] cachedFor: ${source.cachedFor}');
      }

      // Check for cache-eligible LocalAndRemoteSource queries
      if (source is LocalAndRemoteSource && source.cachedFor != null) {
        print('[query] Taking CACHED path');
        await _queryCached(req, source);
        // For LocalAndRemoteSource, always query local at the end
        // (covers both fresh and stale, since remote saves to local)
      } else {
        print('[query] Taking NON-CACHED path');
        // Original non-cached path
        final future = _sendMessage(
          RemoteQueryIsolateOperation(req: req, source: source),
        );

        if (source.background) {
          unawaited(future);
        } else {
          final response = await future;

          if (!response.success) {
            throw IsolateException(response.error);
          }

          // ONLY return here if source has no local
          if (source is! LocalAndRemoteSource) {
            final result = response.result as List<Map<String, dynamic>>;
            return result.toModels<E>(ref).toSet().sortByCreatedAt();
          }
        }
      }
    }

    print('[query] Querying LOCAL storage for ${E.toString()}');
    final pairs = req.filters.map((f) => f.toSQL()).toList();
    print('[query] SQL pairs count: ${pairs.length}');
    final queries = LocalQueryArgs.fromPairs(pairs);
    final response = await _sendMessage(
      LocalQueryIsolateOperation({req: queries}),
    );
    if (!response.success) {
      print('[query] LOCAL query FAILED: ${response.error}');
      throw IsolateException(response.error);
    }

    final result =
        response.result as Map<Request, Iterable<Map<String, dynamic>>>;
    final models = result[req]!.toModels<E>(ref).toSet().sortByCreatedAt();
    print('[query] LOCAL query returned ${models.length} ${E.toString()} models');
    if (models.isNotEmpty) {
      print('[query] First model: ${models.first}');
    }
    return models;
  }

  /// Handle cached query: split filters into fresh/stale, query remote for stale only
  Future<void> _queryCached<E extends Model<dynamic>>(
    Request<E> req,
    LocalAndRemoteSource source,
  ) async {
    print('[_queryCached] Starting for ${E.toString()}, cachedFor: ${source.cachedFor}');
    print('[_queryCached] Request filters count: ${req.filters.length}');
    
    final staleFilters = <RequestFilter<E>>[];
    final now = DateTime.now();

    for (final filter in req.filters) {
      print('[_queryCached] Filter: kinds=${filter.kinds}, authors=${filter.authors.length} authors');
      print('[_queryCached] Filter isCacheable: ${_isCacheableFilter(filter)}');
      
      if (!_isCacheableFilter(filter)) {
        // Not cacheable - always query remote
        print('[_queryCached] Filter NOT cacheable, adding to stale');
        staleFilters.add(filter);
        continue;
      }

      // Check each (kind, author) pair individually
      final staleAuthors = <String>{};

      for (final author in filter.authors) {
        for (final kind in filter.kinds) {
          final cacheKey = '$kind:$author';
          final lastFetch = _authorKindCache[cacheKey];

          print('[_queryCached] Checking cache key: $cacheKey, lastFetch: $lastFetch');
          
          if (lastFetch == null ||
              now.difference(lastFetch) >= source.cachedFor!) {
            print('[_queryCached] Author $author is STALE for kind $kind');
            staleAuthors.add(author);
          } else {
            print('[_queryCached] Author $author is FRESH for kind $kind (age: ${now.difference(lastFetch)})');
          }
        }
      }

      if (staleAuthors.isNotEmpty) {
        print('[_queryCached] Adding ${staleAuthors.length} stale authors to query');
        staleFilters.add(filter.copyWith(authors: staleAuthors));
      } else {
        print('[_queryCached] All authors are fresh, skipping remote query');
      }
    }

    // Query remote only for stale filters
    if (staleFilters.isEmpty) {
      print('[_queryCached] No stale filters, returning early');
      return;
    }

    print('[_queryCached] Querying remote for ${staleFilters.length} stale filters');
    final staleReq = Request<E>(staleFilters);
    final future = _sendMessage(
      RemoteQueryIsolateOperation(req: staleReq, source: source),
    );

    if (!source.background) {
      final response = await future;
      if (!response.success) {
        print('[_queryCached] Remote query FAILED: ${response.error}');
        throw IsolateException(response.error);
      }
      final remoteResult = response.result as List<Map<String, dynamic>>?;
      print('[_queryCached] Remote query returned ${remoteResult?.length ?? 0} events');
      if (remoteResult != null && remoteResult.isNotEmpty) {
        print('[_queryCached] First remote event kind: ${remoteResult.first['kind']}, pubkey: ${remoteResult.first['pubkey']}');
      }
      print('[_queryCached] Remote query complete, updating cache timestamps');
      _updateCacheTimestamps(staleFilters, now);
    } else {
      unawaited(
        future.then((response) {
          final remoteResult = response.result as List<Map<String, dynamic>>?;
          print('[_queryCached] Background remote query returned ${remoteResult?.length ?? 0} events');
          print('[_queryCached] Background remote query complete, updating cache timestamps');
          _updateCacheTimestamps(staleFilters, DateTime.now());
        }),
      );
    }
  }

  /// Update cache timestamps for cacheable filters
  void _updateCacheTimestamps(List<RequestFilter> filters, DateTime timestamp) {
    for (final filter in filters) {
      if (_isCacheableFilter(filter)) {
        for (final author in filter.authors) {
          for (final kind in filter.kinds) {
            _authorKindCache['$kind:$author'] = timestamp;
          }
        }
      }
    }
  }

  @override
  Future<void> cancel(Request req, {Source? source}) async {
    if (source is LocalSource) return;

    final response = await _sendMessage(RemoteCancelIsolateOperation(req: req));

    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  @override
  Future<void> obliterate() async {
    if (config.databasePath == null) return;
    // Directory where database is located
    final dir = Directory(path.dirname(config.databasePath!));
    final name = path.basename(config.databasePath!);
    for (final e in await dir.list().toList()) {
      if (e is File && path.basename(e.path).startsWith(name)) {
        await e.delete();
      }
    }
  }

  @override
  void dispose() {
    if (!isInitialized) return;

    _heartbeatTimer?.cancel();
    sub?.cancel();

    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
    _initCompleter = null;
    isInitialized = false;

    if (mounted) {
      super.dispose();
    }
  }

  /// Check if a filter is cacheable (author+kind only, replaceable kinds)
  bool _isCacheableFilter(RequestFilter filter) {
    print('[_isCacheableFilter] Checking filter:');
    print('[_isCacheableFilter]   authors: ${filter.authors} (empty: ${filter.authors.isEmpty})');
    print('[_isCacheableFilter]   kinds: ${filter.kinds} (empty: ${filter.kinds.isEmpty})');
    print('[_isCacheableFilter]   ids: ${filter.ids} (empty: ${filter.ids.isEmpty})');
    print('[_isCacheableFilter]   tags: ${filter.tags} (empty: ${filter.tags.isEmpty})');
    print('[_isCacheableFilter]   search: ${filter.search}');
    print('[_isCacheableFilter]   until: ${filter.until}');
    
    // Must have authors
    if (filter.authors.isEmpty) {
      print('[_isCacheableFilter] FAIL: no authors');
      return false;
    }

    // Must have kinds
    if (filter.kinds.isEmpty) {
      print('[_isCacheableFilter] FAIL: no kinds');
      return false;
    }

    // All kinds must be replaceable
    for (final kind in filter.kinds) {
      print('[_isCacheableFilter]   kind $kind isReplaceable: ${Utils.isEventReplaceable(kind)}');
    }
    if (!filter.kinds.every(Utils.isEventReplaceable)) {
      print('[_isCacheableFilter] FAIL: not all kinds are replaceable');
      return false;
    }

    // Must NOT have: ids, tags, search, until
    if (filter.ids.isNotEmpty) {
      print('[_isCacheableFilter] FAIL: has ids');
      return false;
    }
    if (filter.tags.isNotEmpty) {
      print('[_isCacheableFilter] FAIL: has tags');
      return false;
    }
    if (filter.search != null) {
      print('[_isCacheableFilter] FAIL: has search');
      return false;
    }
    if (filter.until != null) {
      print('[_isCacheableFilter] FAIL: has until');
      return false;
    }

    print('[_isCacheableFilter] SUCCESS: filter is cacheable');
    return true;
  }

  Future<IsolateResponse> _sendMessage(IsolateOperation operation) async {
    // Check if the isolate has been disposed
    if (!isInitialized) {
      throw IsolateException('Storage has been disposed');
    }

    try {
      await _initCompleter!.future.timeout(
        // TODO: Configurable
        Duration(seconds: 12),
        onTimeout: () => IsolateResponse(success: false, error: 'Timeout'),
      );

      // Double-check after waiting - dispose might have been called while waiting
      if (!isInitialized) {
        throw IsolateException('Storage has been disposed');
      }

      final receivePort = ReceivePort();
      _sendPort!.send((operation, receivePort.sendPort));

      return await receivePort.first as IsolateResponse;
    } catch (e, stack) {
      if (e is Error) {
        throw IsolateException(e.toString(), stack);
      }
      rethrow;
    }
  }
}
