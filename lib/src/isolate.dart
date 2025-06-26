import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:models/models.dart';
import 'package:purplebase/src/utils.dart';
import 'package:purplebase/src/db.dart';
import 'package:purplebase/src/websocket_pool.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as path;

void isolateEntryPoint(List args) {
  final [SendPort mainSendPort, StorageConfiguration config] = args;

  // Create a receive port for incoming messages
  final receivePort = ReceivePort();

  // Send this isolate's SendPort back to the main isolate
  mainSendPort.send(receivePort.sendPort);

  void Function()? closeFn;
  StreamSubscription? sub;

  final pool = WebSocketPool(config);

  Database? db;
  try {
    if (config.databasePath != null) {
      final dirPath = path.join(Directory.current.path, config.databasePath);
      db = sqlite3.open(dirPath);
    } else {
      db = sqlite3.openInMemory();
    }
    db.initialize();
  } catch (e) {
    print('Error opening database: $e');
  }

  // Listen for messages from websocket pool
  closeFn = pool.addListener((response) {
    if (response case EventRelayResponse(
      :final req,
      :final events,
      :final relaysForIds,
    )) {
      final ids = db!.save(events, relaysForIds, config);
      mainSendPort.send((ids, req));
    }
  });

  // Listen for messages from main isolate (UI)
  sub = receivePort.listen((message) async {
    if (message case (
      final IsolateOperation operation,
      final SendPort replyPort,
    )) {
      IsolateResponse response;

      switch (operation) {
        // LOCAL STORAGE

        case LocalQueryIsolateOperation(:final args):
          try {
            final result = db!.find(args);
            response = IsolateResponse(success: true, result: result);
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
          }

        case LocalSaveIsolateOperation(:final events):
          try {
            final ids = db!.save(events, {}, config);
            response = IsolateResponse(success: true, result: ids);
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
          }

        case LocalClearIsolateOperation():
          try {
            db!.initialize(clear: true);
            response = IsolateResponse(success: true);
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
          }

        // REMOTE

        case RemoteQueryIsolateOperation(:final req, :final source):
          final relayUrls = config.getRelays(source: source);
          final result = await pool.query(req, relayUrls: relayUrls);
          // No saving here, events are saved in the callback as query also emits
          response = IsolateResponse(success: true, result: result.decoded());

        case RemotePublishIsolateOperation(:final events, :final source):
          final relayUrls = config.getRelays(source: source, useDefault: true);
          final result = await pool.publish(events, relayUrls: relayUrls);
          response = IsolateResponse(success: true, result: result);

        case RemoteCancelIsolateOperation(:final req):
          pool.unsubscribe(req);
          response = IsolateResponse(success: true);

        // ISOLATE

        case CloseIsolateOperation():
          db?.dispose();
          pool.dispose();
          closeFn?.call();
          response = IsolateResponse(success: true);
          Future.microtask(() => sub?.cancel());
      }

      replyPort.send(response);
    }
  });
}

//

sealed class IsolateOperation {}

final class LocalQueryIsolateOperation extends IsolateOperation {
  final Map<Request, LocalQueryArgs> args;
  LocalQueryIsolateOperation(this.args);
}

final class LocalQueryArgs {
  final List<String> queries;
  final List<Map<String, dynamic>> params;

  LocalQueryArgs({required this.queries, required this.params}) {
    if (queries.length != params.length) {
      throw Exception('Bad amount of arguments');
    }
  }

  factory LocalQueryArgs.fromPairs(List<(String, Map<String, dynamic>)> pairs) {
    final queries = pairs.map((q) => q.$1).toList();
    final params = pairs.map((q) => q.$2).toList();
    return LocalQueryArgs(queries: queries, params: params);
  }
}

final class LocalSaveIsolateOperation extends IsolateOperation {
  final Set<Map<String, dynamic>> events;
  LocalSaveIsolateOperation({required this.events});
}

final class RemotePublishIsolateOperation extends IsolateOperation {
  final List<Map<String, dynamic>> events;
  final RemoteSource source;

  RemotePublishIsolateOperation({required this.events, required this.source});
}

final class RemoteQueryIsolateOperation extends IsolateOperation {
  final Request req;
  final RemoteSource source;
  RemoteQueryIsolateOperation({required this.req, required this.source});
}

final class RemoteCancelIsolateOperation extends IsolateOperation {
  final Request req;
  RemoteCancelIsolateOperation({required this.req});
}

final class LocalClearIsolateOperation extends IsolateOperation {}

final class CloseIsolateOperation extends IsolateOperation {}

/// Response from isolate
class IsolateResponse {
  final bool success;
  final dynamic result;
  final String? error;

  IsolateResponse({required this.success, this.result, this.error});
}

class IsolateException implements Exception {
  final String? message;
  IsolateException([this.message]);

  @override
  String toString() => 'IsolateException: $message';
}
