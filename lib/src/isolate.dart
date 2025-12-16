import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:models/models.dart';
import 'package:purplebase/src/utils.dart';
import 'package:purplebase/src/db.dart';
import 'package:purplebase/src/pool/pool.dart';
import 'package:purplebase/src/pool/state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as path;

void isolateEntryPoint(List args) {
  final [
    SendPort mainSendPort,
    StorageConfiguration config,
    Verifier verifier,
  ] = args;

  // Create a receive port for incoming messages
  final receivePort = ReceivePort();
  StreamSubscription? sub;

  // Track which subscriptions should send QueryResultMessage
  // Streaming queries and fetch() need this (blocking queries return via IsolateResponse)
  final Set<String> callbackSubscriptions = {};

  // Initialize database first
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
    // Can't send state yet, just fail silently
    // Don't send SendPort if initialization failed
    return;
  }

  // Create pool with callbacks (after db is initialized)
  final pool = RelayPool(
    config: config,
    onStateChange: (state) {
      mainSendPort.send(PoolStateMessage(state));
    },
    onEvents: ({
      required Request req,
      required List<Map<String, dynamic>> events,
      required Map<String, Set<String>> relaysForIds,
    }) {
      if (events.isEmpty) return;

      final ids = db!.save(events.toSet(), relaysForIds, config, verifier);

      // Only send QueryResultMessage for subscriptions that use callbacks
      // Blocking queries return data directly via IsolateResponse
      if (callbackSubscriptions.contains(req.subscriptionId)) {
        mainSendPort.send(QueryResultMessage(request: req, savedIds: ids));
      }
    },
  );

  // Send SendPort AFTER database and pool are initialized
  mainSendPort.send(receivePort.sendPort);

  // Listen for messages from main isolate (UI)
  sub = receivePort.listen((message) async {
    // Handle heartbeat messages (no reply needed)
    if (message is HeartbeatMessage) {
      try {
        switch (message.action) {
          case HeartbeatAction.connect:
            pool.connect();
          case HeartbeatAction.disconnect:
            pool.disconnect();
          case HeartbeatAction.healthCheck:
            await pool.performHealthCheck();
        }
      } catch (_) {
        // Errors are logged in pool state
      }
      return;
    }

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
            final ids = db!.save(events, {}, config, verifier);
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
          // Streaming queries need callback tracking
          if (source.stream) {
            callbackSubscriptions.add(req.subscriptionId);
          }

          final result = await pool.query(req, source: source);
          // For stream=true, pool returns [] immediately
          // For stream=false, pool waits for all EOSEs and returns data
          response = IsolateResponse(success: true, result: result.decoded());

        case RemotePublishIsolateOperation(:final events, :final source):
          final result = await pool.publish(events, source: source);
          response = IsolateResponse(success: true, result: result);

        case RemoteCancelIsolateOperation(:final req):
          pool.unsubscribe(req);
          callbackSubscriptions.remove(req.subscriptionId);
          response = IsolateResponse(success: true);

        // ISOLATE

        case CloseIsolateOperation():
          db?.dispose();
          pool.dispose();
          response = IsolateResponse(success: true);
          Future.microtask(() => sub?.cancel());
      }

      replyPort.send(response);
    }
  });
}

//

/// Base class for all messages sent from background isolate to main isolate
sealed class IsolateMessage {
  final timestamp = DateTime.now();
}

/// Message containing query results (replaces the (ids, req) tuple)
final class QueryResultMessage extends IsolateMessage {
  final Request request;
  final Set<String> savedIds;

  QueryResultMessage({required this.request, required this.savedIds});
}

/// Message containing pool state information
final class PoolStateMessage extends IsolateMessage {
  final PoolState poolState;
  PoolStateMessage(this.poolState);
}

/// Action type for heartbeat messages
enum HeartbeatAction { healthCheck, connect, disconnect }

/// Heartbeat message from main isolate to trigger health checks or connection changes
final class HeartbeatMessage {
  final DateTime timestamp;
  final HeartbeatAction action;
  HeartbeatMessage(this.timestamp, {this.action = HeartbeatAction.healthCheck});
}

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
  final StackTrace? stackTrace;
  IsolateException([this.message, this.stackTrace]);

  @override
  String toString() => 'IsolateException: $message';
}
