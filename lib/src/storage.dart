import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/utils.dart';
import 'package:purplebase/src/websocket_pool.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

/// Singleton
class PurplebaseStorageNotifier extends StorageNotifier {
  final Ref ref;

  static PurplebaseStorageNotifier? _instance;

  factory PurplebaseStorageNotifier(Ref ref) {
    return _instance ??= PurplebaseStorageNotifier._internal(ref);
  }

  PurplebaseStorageNotifier._internal(this.ref);

  late final Database db;
  var _initialized = false;

  Isolate? _isolate;
  SendPort? _sendPort;
  final _initCompleter = Completer<void>();
  StreamSubscription? sub;

  /// Initialize the storage with a configuration
  @override
  Future<void> initialize(StorageConfiguration config) async {
    await super.initialize(config);

    if (_initialized) return;

    final dirPath = path.join(Directory.current.path, config.databasePath);
    db = sqlite3.open(dirPath);

    // Configure sqlite: 1 GB memory mapped
    db.execute('''
      PRAGMA mmap_size = ${1 * 1024 * 1024 * 1024};
      PRAGMA page_size = 4096;
      PRAGMA cache_size = -20000;
      ''');

    // Initialize isolate
    if (_isolate != null) return _initCompleter.future;

    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(isolateEntryPoint, [
      receivePort.sendPort,
      config,
    ]);

    sub = receivePort.listen((message) {
      if (_sendPort == null && message is SendPort) {
        _sendPort = message;
        _initCompleter.complete();
      } else {
        state = InternalStorageData(message as Set<String>);
      }
    });

    await _initCompleter.future;
    _initialized = true;
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

    state = InternalStorageData(response.result as Set<String>);

    return true;
  }

  /// Publish
  @override
  Future<PublishResponse> publish(
    Set<Model<dynamic>> events, {
    Source? source,
  }) async {
    if (events.isEmpty && source == LocalSource()) {
      return PublishResponse();
    }

    final maps = events.map((e) => e.toMap()).toList();

    final response = await _sendMessage(
      RemotePublishIsolateOperation(
        events: maps,
        source: source as RemoteSource? ?? RemoteSource(),
      ),
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
    final events = <Map<String, dynamic>>[];
    final relayUrls = config.getRelays(
      source: LocalSource(),
      useDefault: false,
    );

    final tuples =
        req.filters
            .map((f) => f.toSQL(onIds: onIds, relayUrls: relayUrls))
            .toList();
    final statements = db.prepareMultiple(tuples.map((t) => t.$1).join(';\n'));
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
    Source source = const LocalSource(),
    Set<String>? onIds,
  }) async {
    // If by any chance req is in cache, return that
    final cachedEvents =
        requestCache.values.firstWhereOrNull((m) => m.containsKey(req))?[req];
    if (cachedEvents != null) {
      return cachedEvents.cast();
    }

    // TODO: Should query for replaceable too
    // final replaceableIds = req.ids.where(kReplaceableRegexp.hasMatch);
    // final regularIds = {...req.ids}..removeAll(replaceableIds);

    final relayUrls = config.getRelays(source: source, useDefault: false);

    final events = <Map<String, dynamic>>[];

    if (source case LocalSource() || RemoteSource(includeLocal: true)) {
      final queries =
          req.filters
              .map((f) => f.toSQL(onIds: onIds, relayUrls: relayUrls))
              .toList();
      final response = await _sendMessage(LocalQueryIsolateOperation(queries));
      if (!response.success) {
        throw IsolateException(response.error);
      }
      events.addAll((response.result as Iterable).cast());
    }

    // TODO: Should have a timeout for isolate as well

    if (source case RemoteSource()) {
      final response = await _sendMessage(
        RemoteQueryIsolateOperation(req: req, source: source),
      );

      if (!response.success) {
        throw IsolateException(response.error);
      }
      events.addAll((response.result as Iterable).cast());
    }

    return events
        .map((e) {
          return Model.getConstructorForKind(e['kind']!)!.call(e, ref);
        })
        .toList()
        .cast();
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
  void dispose() {
    if (!_initialized || _isolate == null) return;

    sub?.cancel();

    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
    _initialized = false;

    if (mounted) {
      super.dispose();
    }
  }

  Future<IsolateResponse> _sendMessage(IsolateOperation operation) async {
    await _initCompleter.future;

    final receivePort = ReceivePort();
    _sendPort!.send((operation, receivePort.sendPort));

    return await receivePort.first as IsolateResponse;
  }
}
