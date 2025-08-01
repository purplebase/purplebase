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

class PurplebaseStorageNotifier extends StorageNotifier {
  final Ref ref;

  PurplebaseStorageNotifier(this.ref);

  Database? db;
  Isolate? _isolate;
  SendPort? _sendPort;
  Completer<void>? _initCompleter;
  StreamSubscription? sub;

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
        case InfoMessage infoMessage:
          ref.read(infoNotifierProvider.notifier).emit(infoMessage);
        case RelayStatusMessage relayStatusMessage:
          ref
              .read(relayStatusProvider.notifier)
              .emit(relayStatusMessage.statusData);
      }
    });

    await _initCompleter!.future;
    isInitialized = true;
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
  }) async {
    source ??= config.defaultQuerySource;

    if (req.filters.isEmpty) return [];
    final results = <E>{};

    if (source case LocalSource() || LocalAndRemoteSource()) {
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
      results.addAll(result[req]!.toModels(ref));
    }

    if (source case RemoteSource()) {
      final future = _sendMessage(
        RemoteQueryIsolateOperation(req: req, source: source),
      );
      if (results.isNotEmpty && source.background) {
        // If we have results, return now, if not block until EOSE
        return results.sortByCreatedAt();
      }
      final response = await future;

      if (!response.success) {
        throw IsolateException(response.error);
      }

      final result = response.result as List<Map<String, dynamic>>;
      results.addAll(result.toModels(ref));
    }
    return results.sortByCreatedAt();
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

  Future<IsolateResponse> _sendMessage(IsolateOperation operation) async {
    // Check if the isolate has been disposed
    if (!isInitialized) {
      throw IsolateException('Storage has been disposed');
    }

    try {
      await _initCompleter!.future.timeout(
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
