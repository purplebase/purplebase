import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import '../db/codec.dart';
import '../db/database.dart';
import '../db/query_builder.dart';
import '../db/schema.dart' as schema;
import '../isolate/isolate_bridge.dart';
import '../isolate/isolate_entry.dart';
import '../isolate/messages.dart';
import '../notifiers/pool_state_notifier.dart';
import '../pool/pool_state.dart';
import '../pool/relay_pool.dart';
import 'cache.dart';

/// PurplebaseStorageNotifier — the concrete StorageNotifier backed by
/// SQLite + a background isolate running the relay pool.
class PurplebaseStorageNotifier extends StorageNotifier {
  PurplebaseStorageNotifier(super.ref);

  Database? db;
  Isolate? _isolate;
  IsolateBridge? _bridge;
  Completer<void>? _initCompleter;
  StreamSubscription? _isolateSub;
  Timer? _heartbeatTimer;

  final AuthorKindCache _cache = AuthorKindCache();

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

    db!.execute(schema.setUpSql);

    final verifier = ref.read(verifierProvider);

    if (_isolate != null) return _initCompleter!.future;

    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(isolateEntryPoint, [
      receivePort.sendPort,
      config,
      verifier,
    ]);

    _isolateSub = receivePort.listen((message) {
      switch (message) {
        case SendPort() when _bridge == null:
          _bridge = IsolateBridge(message);
          _initCompleter!.complete();
        case QueryResultNotification(:final request, :final savedIds)
            when savedIds.isNotEmpty:
          invalidateQueryCache();
          state = InternalStorageData(updatedIds: savedIds, req: request);
        case PoolStateNotification(:final poolState):
          ref.read(poolStateProvider.notifier).emit(poolState);
      }
    });

    await _initCompleter!.future;
    isInitialized = true;

    _startHeartbeat();
    _watchConnectivity();
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(PoolConstants.healthCheckInterval, (_) {
      _bridge?.sendHeartbeat(HeartbeatMessage(DateTime.now()));
    });
  }

  /// Watch connectivity provider and forward status to the pool.
  void _watchConnectivity() {
    ref.listen<ConnectivityStatus>(connectivityProvider, (_, status) {
      _bridge?.sendHeartbeat(
        HeartbeatMessage(
          DateTime.now(),
          action: HeartbeatAction.healthCheck,
          connectivity: status,
        ),
      );
    });
  }

  void connect() {
    if (!isInitialized) return;
    _bridge?.sendHeartbeat(
      HeartbeatMessage(DateTime.now(), action: HeartbeatAction.connect),
    );
  }

  void disconnect() {
    if (!isInitialized) return;
    _bridge?.sendHeartbeat(
      HeartbeatMessage(DateTime.now(), action: HeartbeatAction.disconnect),
    );
  }

  @override
  Future<bool> save(Set<Model<dynamic>> events) async {
    if (events.isEmpty) return true;

    invalidateQueryCache();

    final maps = events.map((e) => e.toMap()).toSet();

    final response = await _sendMessage(LocalSaveOp(events: maps));

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

  @override
  Future<PublishResponse> publish(
    Set<Model<dynamic>> events, {
    dynamic relays,
  }) async {
    if (events.isEmpty) {
      return PublishResponse();
    }

    final maps = events.map((e) => e.toMap()).toList();

    final relayUrls = await resolveRelays(relays);
    final response = await _sendMessage(
      RemotePublishOp(events: maps, relays: relayUrls),
    );

    if (!response.success) {
      throw IsolateException(response.error);
    }

    return (response.result as PublishRelayResponse).wrapped;
  }

  @override
  Future<void> clear([Request? req]) async {
    invalidateQueryCache();
    _cache.clear();

    final response = await _sendMessage(LocalClearOp());
    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  /// Delete events by IDs (NIP-09).
  Future<void> delete(Set<String> eventIds) async {
    if (eventIds.isEmpty) return;
    final response = await _sendMessage(LocalDeleteOp(eventIds: eventIds));
    if (!response.success) {
      throw IsolateException(response.error);
    }
    invalidateQueryCache();
    state = InternalStorageData(updatedIds: eventIds, req: null);
  }

  /// Prune old non-replaceable events.
  Future<void> prune({Duration? olderThan}) async {
    final age = olderThan ?? const Duration(days: 30);
    final response = await _sendMessage(LocalPruneOp(olderThan: age));
    if (!response.success) {
      throw IsolateException(response.error);
    }

    // WAL checkpoint on the main isolate's connection too
    db?.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    invalidateQueryCache();
  }

  @override
  List<E> querySync<E extends Model<dynamic>>(Request<E> req) {
    if (db == null) {
      throw IsolateException('Storage has been disposed');
    }

    final results = <E>[];

    final tuples = req.filters.map((f) => QueryBuilder.toSQL(f)).toList();
    final statements = db!.prepareMultiple(tuples.map((t) => t.$1).join(';\n'));
    try {
      for (var i = 0; i < statements.length; i++) {
        final filter = req.filters[i];
        final result = statements[i].selectWith(
          StatementParameters.named(tuples[i].$2),
        );
        var events = EventCodec.decode(result);

        if (filter.schemaFilter != null) {
          events = events.where(filter.schemaFilter!).toList();
        }

        results.addAll(
          events
              .map((e) => Model.getConstructorForKind(e['kind'])!.call(e, ref))
              .cast<E>(),
        );
      }
    } finally {
      for (final statement in statements) {
        statement.dispose();
      }
    }

    return results;
  }

  /// Query relay URLs where an event has been seen (for SeenOnRelays).
  Set<String> queryRelaysForEvent(String eventId) {
    if (db == null) return {};
    return db!.queryRelaysForEvent(eventId);
  }

  @override
  Future<List<E>> query<E extends Model<dynamic>>(
    Request<E> req, {
    Source? source,
    String? subscriptionPrefix,
  }) async {
    source ??= config.defaultQuerySource;

    if (req.filters.isEmpty) return [];

    if (source case RemoteSource()) {
      final relayUrls = await resolveRelays(source.relays);
      source = source.copyWith(relays: relayUrls);

      if (source is LocalAndRemoteSource && source.cachedFor != null) {
        await _queryCached(req, source, relayUrls);
      } else {
        final response = await _sendMessage(
          RemoteQueryOp(req: req, source: source),
        );

        if (!response.success) {
          throw IsolateException(response.error);
        }

        if (source is! LocalAndRemoteSource) {
          var result = response.result as List<Map<String, dynamic>>;
          result = _applySchemaFilters(result, req.filters);
          return result.toModels<E>(ref).toSet().toList();
        }
      }
    }

    final pairs = req.filters.map((f) => QueryBuilder.toSQL(f)).toList();
    final queries = LocalQueryArgs.fromPairs(pairs);
    final response = await _sendMessage(LocalQueryOp({req: queries}));
    if (!response.success) {
      throw IsolateException(response.error);
    }

    final result =
        response.result as Map<Request, Iterable<Map<String, dynamic>>>;
    final filtered = _applySchemaFilters(result[req]!.toList(), req.filters);
    return filtered.toModels<E>(ref).toSet().sortByCreatedAt();
  }

  List<Map<String, dynamic>> _applySchemaFilters(
    List<Map<String, dynamic>> events,
    List<RequestFilter> filters,
  ) {
    final schemaFilters = filters
        .map((f) => f.schemaFilter)
        .whereType<SchemaFilter>()
        .toList();

    if (schemaFilters.isEmpty) return events;

    return events.where((event) {
      return schemaFilters.every((filter) => filter(event));
    }).toList();
  }

  Future<void> _queryCached<E extends Model<dynamic>>(
    Request<E> req,
    LocalAndRemoteSource source,
    Set<String> relayUrls,
  ) async {
    final staleFilters = <RequestFilter<E>>[];
    final now = DateTime.now();

    for (final filter in req.filters) {
      final staleAuthors = _cache.staleAuthors(filter, source.cachedFor!);
      if (staleAuthors.isNotEmpty) {
        staleFilters.add(filter.copyWith(authors: staleAuthors));
      }
    }

    if (staleFilters.isEmpty) return;

    final staleReq = Request<E>(staleFilters);
    final response = await _sendMessage(
      RemoteQueryOp(req: staleReq, source: source),
    );

    if (!response.success) {
      throw IsolateException(response.error);
    }

    // Only mark authors as cached if data was actually returned.
    // Authors with no data (relay timeout, not found) stay stale
    // so they'll be re-fetched on the next query.
    final local = querySync(staleReq);
    final foundAuthors = local.map((m) => m.event.pubkey).toSet();
    final successFilters = staleFilters
        .map((f) {
          final hit = f.authors.intersection(foundAuthors);
          return hit.isEmpty ? null : f.copyWith(authors: hit);
        })
        .nonNulls
        .toList();
    if (successFilters.isNotEmpty) {
      _cache.markFetched(successFilters.cast(), now);
    }
  }

  @override
  Future<void> cancel(Request req) async {
    final response = await _sendMessage(RemoteCancelOp(req: req));
    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  @override
  Future<void> closeSubscriptions({required dynamic relays}) async {
    if (!isInitialized) return;

    final relayUrls = await resolveRelays(relays);
    if (relayUrls.isEmpty) return;

    final response = await _sendMessage(
      CloseSubscriptionsOp(relayUrls: relayUrls),
    );

    if (!response.success) {
      throw IsolateException(response.error);
    }
  }

  @override
  Future<void> obliterate() async {
    if (config.databasePath == null) return;
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
    _isolateSub?.cancel();

    _isolate?.kill();
    _isolate = null;
    _bridge = null;
    _initCompleter = null;
    isInitialized = false;

    if (mounted) {
      super.dispose();
    }
  }

  Future<IsolateResponse> _sendMessage(IsolateOperation operation) async {
    if (!isInitialized) {
      throw IsolateException('Storage has been disposed');
    }

    try {
      await _initCompleter!.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw IsolateException('Initialization timeout'),
      );

      if (!isInitialized) {
        throw IsolateException('Storage has been disposed');
      }

      return await _bridge!.send(operation);
    } catch (e, stack) {
      if (e is Error) {
        throw IsolateException(e.toString(), stack);
      }
      rethrow;
    }
  }
}
