import 'dart:async';
import 'dart:isolate';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/websocket_pool.dart';
import 'package:riverpod/riverpod.dart';

/// Singleton
class PurplebaseStorageNotifier extends StorageNotifier {
  final Ref ref;

  static PurplebaseStorageNotifier? _instance;

  factory PurplebaseStorageNotifier(Ref ref) {
    return _instance ??= PurplebaseStorageNotifier._internal(ref);
  }

  PurplebaseStorageNotifier._internal(this.ref);

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
        case (Set<String> ids, Request? req) when ids.isNotEmpty:
          state = InternalStorageData(updatedIds: ids, req: req);
      }

      if (_sendPort == null && message is SendPort) {
        _sendPort = message;
        _initCompleter.complete();
      } else {}
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
  Future<List<E>> query<E extends Model<dynamic>>(
    Request<E> req, {
    Source source = const LocalSource(),
  }) async {
    if (req.filters.isEmpty) return [];

    // Delegate to internalMultipleQuery and extract the single result
    final results = await internalMultipleQuery([req], source: source);
    return results[req]?.cast<E>() ?? [];
  }

  @override
  Future<Map<Request<Model<dynamic>>, List<Model<dynamic>>>>
  internalMultipleQuery(
    List<Request<Model<dynamic>>> requests, {
    Source source = const RemoteSource(),
  }) async {
    if (requests.isEmpty) return {};

    // print('enters internalMultipleQuery with ${requests.length} requests, source: ${source.runtimeType}');

    // Group requests by equality to avoid duplicate processing
    final uniqueRequests =
        <Request<Model<dynamic>>, List<Request<Model<dynamic>>>>{};
    for (final request in requests) {
      final existing = uniqueRequests.keys.firstWhere(
        (r) => r == request,
        orElse: () => request,
      );
      if (existing == request) {
        uniqueRequests[request] = [request];
      } else {
        uniqueRequests[existing]!.add(request);
      }
    }

    final result = <Request<Model<dynamic>>, List<Model<dynamic>>>{};

    // Step 1: Process local queries separately for each unique request
    final localResults = <Request<Model<dynamic>>, List<Model<dynamic>>>{};
    final requestsNeedingRemote = <Request<Model<dynamic>>>[];
    final requestsForBackground = <Request<Model<dynamic>>>[];

    if (source.returnModels || source is RemoteSource && source.includeLocal) {
      // Process local queries for all unique requests
      final requestArgs = <Request, LocalQueryArgs>{};

      for (final request in uniqueRequests.keys) {
        final pairs = request.filters.map((f) => f.toSQL()).toList();
        final args = LocalQueryArgs.fromPairs(pairs);
        requestArgs[request] = args;
      }

      final response = await _sendMessage(
        LocalQueryIsolateOperation(requestArgs),
      );

      if (!response.success) {
        throw IsolateException(response.error);
      }

      final results =
          response.result as Map<Request, List<Map<String, dynamic>>>;

      // Convert results to models and determine background vs blocking behavior
      for (final entry in results.entries) {
        final models = entry.value.toModels(ref).toList();
        localResults[entry.key] = models;

        // Determine if this request needs background or blocking remote query
        final isBackgroundRemoteQuery = models.isNotEmpty;
        if (source is RemoteSource) {
          if (isBackgroundRemoteQuery) {
            requestsForBackground.add(entry.key);
          } else {
            requestsNeedingRemote.add(entry.key);
          }
        }
      }
    }

    // Step 2: Handle blocking remote queries (performed separately)
    final remoteResults = <Request<Model<dynamic>>, List<Model<dynamic>>>{};

    if (requestsNeedingRemote.isNotEmpty && source is RemoteSource) {
      // print('blocking remote queries for ${requestsNeedingRemote.length} requests');

      for (final request in requestsNeedingRemote) {
        final response = await _sendMessage(
          RemoteQueryIsolateOperation(req: request, source: source),
        );

        if (!response.success) {
          throw IsolateException(response.error);
        }

        final result = response.result as Iterable<Map<String, dynamic>>;
        remoteResults[request] = result.toModels(ref).toList();
      }
    }

    // Step 3: Handle background remote queries (merged for efficiency)
    if (requestsForBackground.isNotEmpty && source is RemoteSource) {
      // print('background remote queries for ${requestsForBackground.length} requests');

      // Use RequestFilter.mergeMultiple to compress requests
      final allFilters =
          requestsForBackground.expand((req) => req.filters).toList();

      final mergedFilters = RequestFilter.mergeMultiple(allFilters);

      // Create merged requests for background fetching

      final mergedRequest = mergedFilters.toRequest();

      // Fire and forget - these will show up via notifier
      _sendMessage(
        RemoteQueryIsolateOperation(req: mergedRequest, source: source),
      ).catchError((error) {
        // print('Background remote query error: $error');
        // Return a dummy response since this is fire-and-forget
        return IsolateResponse(success: false, error: error.toString());
      });
    }

    // Step 4: Combine results and expand to all original requests
    for (final entry in uniqueRequests.entries) {
      final uniqueRequest = entry.key;
      final duplicateRequests = entry.value;

      final localModels = localResults[uniqueRequest] ?? <Model<dynamic>>[];
      final remoteModels = remoteResults[uniqueRequest] ?? <Model<dynamic>>[];

      final combinedModels =
          [...localModels, ...remoteModels].sortByCreatedAt();

      // Add results for all duplicate requests
      for (final request in duplicateRequests) {
        result[request] = combinedModels;
      }
    }

    // print('internalMultipleQuery returning results for ${result.length} requests');
    return result;
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
      await _initCompleter.future;

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
