import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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

  var _initialized = false;

  Database? db;
  Isolate? _isolate;
  SendPort? _sendPort;
  final _initCompleter = Completer<void>();
  StreamSubscription? sub;

  /// Initialize the storage with a configuration
  @override
  Future<void> initialize(StorageConfiguration config) async {
    await super.initialize(config);

    if (_initialized) return;

    if (config.databasePath != null) {
      final dirPath = path.join(Directory.current.path, config.databasePath!);
      db = sqlite3.open(dirPath);
    } else {
      db = sqlite3.openInMemory();
    }

    // Configure sqlite: 1 GB memory mapped
    db!.execute('''
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
      switch (message) {
        case SendPort() when _sendPort == null:
          _sendPort = message;
          _initCompleter.complete();
        case QueryResultMessage(:final request, :final savedIds)
            when savedIds.isNotEmpty:
          state = InternalStorageData(updatedIds: savedIds, req: request);
        case InfoMessage infoMessage:
          ref.read(infoNotifierProvider.notifier).emit(infoMessage);
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

    final result = response.result as Set<String>;
    if (result.isNotEmpty) {
      state = InternalStorageData(updatedIds: result);
    }

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
    // Check if the database has been disposed
    if (db == null) {
      throw IsolateException('Storage has been disposed');
    }

    final events = <Map<String, dynamic>>[];
    final relayUrls = config.getRelays(
      source: LocalSource(),
      useDefault: false,
    );

    final tuples =
        req.filters.map((f) => f.toSQL(relayUrls: relayUrls)).toList();
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
    Source source = const LocalSource(),
    Set<String>? onIds,
  }) async {
    if (req.filters.isEmpty) return [];

    final relayUrls = config.getRelays(source: source, useDefault: true);

    if (source case RemoteSource(:final includeLocal)) {
      final response = await _sendMessage(
        RemoteQueryIsolateOperation(req: req, source: source),
      );

      if (!response.success) {
        throw IsolateException(response.error);
      }

      if (includeLocal == false) {
        final result = response.result as List<Map<String, dynamic>>;
        return result.toModels(ref);
      }
    }

    final pairs =
        req.filters.map((f) => f.toSQL(relayUrls: relayUrls)).toList();
    final queries = LocalQueryArgs.fromPairs(pairs);
    final response = await _sendMessage(
      LocalQueryIsolateOperation({req: queries}),
    );
    if (!response.success) {
      throw IsolateException(response.error);
    }

    final result =
        response.result as Map<Request, Iterable<Map<String, dynamic>>>;
    return result[req]!.toModels(ref);
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

    _instance = null;

    if (mounted) {
      super.dispose();
    }
  }

  Future<IsolateResponse> _sendMessage(IsolateOperation operation) async {
    // Check if the isolate has been disposed
    if (!_initialized || _sendPort == null) {
      throw IsolateException('Storage has been disposed');
    }

    try {
      await _initCompleter.future.timeout(
        Duration(seconds: 12),
        onTimeout: () => IsolateResponse(success: false, error: 'Timeout'),
      );

      // Double-check after waiting - dispose might have been called while waiting
      if (!_initialized || _sendPort == null) {
        throw IsolateException('Storage has been disposed');
      }

      final receivePort = ReceivePort();
      _sendPort!.send((operation, receivePort.sendPort));

      return await receivePort.first as IsolateResponse;
    } catch (e) {
      // If any null check error occurs, convert to IsolateException
      if (e is TypeError &&
          e.toString().contains('Null check operator used on a null value')) {
        throw IsolateException('Storage has been disposed');
      }
      rethrow;
    }
  }
}
