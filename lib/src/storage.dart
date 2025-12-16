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

    if (req.filters.isEmpty) return [];

    if (source case RemoteSource()) {
      final relayUrls = await resolveRelays(source.relays);
      source = source.copyWith(relays: relayUrls);

      // Check for cache-eligible LocalAndRemoteSource queries
      if (source is LocalAndRemoteSource && source.cachedFor != null) {
        await _queryCached(req, source, relayUrls);
        // For LocalAndRemoteSource, always query local at the end
        // (covers both fresh and stale, since remote saves to local)
      } else {
        // Blocking query path
        final response = await _sendMessage(
          RemoteQueryIsolateOperation(req: req, source: source),
        );

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

    final pairs = req.filters.map((f) => f.toSQL()).toList();
    final queries = LocalQueryArgs.fromPairs(pairs);
    final response = await _sendMessage(
      LocalQueryIsolateOperation({req: queries}),
    );
    if (!response.success) {
      throw IsolateException(response.error);
    }

    final result =
        response.result as Map<Request, Iterable<Map<String, dynamic>>>;
    return result[req]!.toModels<E>(ref).toSet().sortByCreatedAt();
  }

  /// Handle cached query: split filters into fresh/stale, query remote for stale only
  Future<void> _queryCached<E extends Model<dynamic>>(
    Request<E> req,
    LocalAndRemoteSource source,
    Set<String> relayUrls,
  ) async {
    final staleFilters = <RequestFilter<E>>[];
    final now = DateTime.now();

    for (final filter in req.filters) {
      if (!_isCacheableFilter(filter)) {
        // Not cacheable - always query remote
        staleFilters.add(filter);
        continue;
      }

      // Check each (kind, author) pair individually
      final staleAuthors = <String>{};

      for (final author in filter.authors) {
        for (final kind in filter.kinds) {
          final cacheKey = '$kind:$author';
          final lastFetch = _authorKindCache[cacheKey];

          if (lastFetch == null ||
              now.difference(lastFetch) >= source.cachedFor!) {
            staleAuthors.add(author);
          }
        }
      }

      if (staleAuthors.isNotEmpty) {
        staleFilters.add(filter.copyWith(authors: staleAuthors));
      }
    }

    // Query remote only for stale filters
    if (staleFilters.isEmpty) return;

    final staleReq = Request<E>(staleFilters);
    final response = await _sendMessage(
      RemoteQueryIsolateOperation(req: staleReq, source: source),
    );

    if (!response.success) {
      throw IsolateException(response.error);
    }
    _updateCacheTimestamps(staleFilters, now);
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
    // Must have authors
    if (filter.authors.isEmpty) return false;

    // Must have kinds
    if (filter.kinds.isEmpty) return false;

    // All kinds must be replaceable
    if (!filter.kinds.every(Utils.isEventReplaceable)) return false;

    // Must NOT have: ids, tags, search, until
    if (filter.ids.isNotEmpty) return false;
    if (filter.tags.isNotEmpty) return false;
    if (filter.search != null) return false;
    if (filter.until != null) return false;

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
