import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:models/models.dart';
import 'package:purplebase/src/utils.dart';
import 'package:purplebase/src/db.dart';
import 'package:purplebase/src/pool/websocket_pool.dart';
import 'package:purplebase/src/pool/state/pool_state.dart';
import 'package:purplebase/src/pool/state/pool_state_notifier.dart';
import 'package:purplebase/src/pool/state/relay_event_notifier.dart';
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

  void Function()? eventCloseFn;
  void Function()? stateCloseFn;
  StreamSubscription? sub;

  // Create notifiers
  final eventNotifier = RelayEventNotifier();
  final stateNotifier = PoolStateNotifier(
    throttleDuration: config.streamingBufferWindow,
  );

  final pool = WebSocketPool(
    config: config,
    eventNotifier: eventNotifier,
    stateNotifier: stateNotifier,
  );

  Database? db;
  try {
    if (config.databasePath != null) {
      final dirPath = path.join(Directory.current.path, config.databasePath);
      db = sqlite3.open(dirPath);
    } else {
      db = sqlite3.openInMemory();
    }
    db.initialize();

    // Send SendPort AFTER database is initialized
    mainSendPort.send(receivePort.sendPort);
  } catch (e) {
    mainSendPort.send(InfoMessage('ERROR: Failed to open database - $e'));
    // Don't send SendPort if initialization failed
    return;
  }

  // Listen for relay events (data channel)
  eventCloseFn = eventNotifier.addListener((event) {
    if (event case EventsReceived(
      :final events,
      :final req,
      :final relaysForIds,
    )) {
      final ids = db!.save(events, relaysForIds, config, verifier);

      // Log save results with comparison
      if (ids.length < events.length) {
        mainSendPort.send(
          InfoMessage(
            'Remote save completed: ${ids.length}/${events.length} event(s) saved (${events.length - ids.length} rejected) [${ids.take(10).join(', ')}${ids.length > 10 ? '...' : ''}]',
          ),
        );
      } else {
        mainSendPort.send(
          InfoMessage(
            'Remote save completed: ${ids.length} event(s) saved [${ids.take(10).join(', ')}${ids.length > 10 ? '...' : ''}]',
          ),
        );
      }

      mainSendPort.send(QueryResultMessage(request: req, savedIds: ids));
    }
    // Handle notices if needed
    // if (event case NoticeReceived(:final message, :final relayUrl)) {
    //   mainSendPort.send(InfoMessage('NOTICE from $relayUrl: $message'));
    // }
  });

  // Listen for pool state updates (meta channel)
  stateCloseFn = stateNotifier.addListener((state) {
    mainSendPort.send(PoolStateMessage(state));
  });

  // Listen for messages from main isolate (UI)
  sub = receivePort.listen((message) async {
    // Handle heartbeat messages (no reply needed)
    if (message is HeartbeatMessage) {
      await pool.performHealthCheck();
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

            // Log save results with comparison
            if (ids.length < events.length) {
              mainSendPort.send(
                InfoMessage(
                  'Local save completed: ${ids.length}/${events.length} event(s) saved (${events.length - ids.length} rejected) [${ids.take(10).join(', ')}${ids.length > 10 ? '...' : ''}]',
                ),
              );
            } else {
              mainSendPort.send(
                InfoMessage(
                  'Local save completed: ${ids.length} event(s) saved [${ids.take(10).join(', ')}${ids.length > 10 ? '...' : ''}]',
                ),
              );
            }
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
            mainSendPort.send(InfoMessage('ERROR: Local save failed - $e'));
          }

        case LocalClearIsolateOperation():
          try {
            db!.initialize(clear: true);
            response = IsolateResponse(success: true);
            mainSendPort.send(
              InfoMessage('Database cleared and reinitialized'),
            );
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
            mainSendPort.send(InfoMessage('ERROR: Database clear failed - $e'));
          }

        // REMOTE

        case RemoteQueryIsolateOperation(:final req, :final source):
          final future = pool.query(req, source: source);
          if (source.background) {
            response = IsolateResponse(
              success: true,
              result: <Map<String, dynamic>>[],
            );
          } else {
            final result = await future;
            // No saving here, events are saved in the callback as query also emits
            response = IsolateResponse(success: true, result: result.decoded());
          }

        case RemotePublishIsolateOperation(:final events, :final source):
          mainSendPort.send(
            InfoMessage(
              'Publishing ${events.length} event(s) to ${config.getRelays(source: source).join(', ')}',
            ),
          );
          final result = await pool.publish(events, source: source);
          response = IsolateResponse(success: true, result: result);

        case RemoteCancelIsolateOperation(:final req):
          pool.unsubscribe(req);
          response = IsolateResponse(success: true);

        // ISOLATE

        case CloseIsolateOperation():
          db?.dispose();
          pool.dispose();
          eventCloseFn?.call();
          stateCloseFn?.call();
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

/// Message containing debug/info information
final class InfoMessage extends IsolateMessage {
  final String message;
  InfoMessage(this.message);
}

/// Message containing pool state information
final class PoolStateMessage extends IsolateMessage {
  final PoolState poolState;
  PoolStateMessage(this.poolState);
}

/// Message containing relay status information (legacy, kept for compatibility)
final class RelayStatusMessage extends IsolateMessage {
  final PoolState statusData;
  RelayStatusMessage(this.statusData);
}

/// Heartbeat message from main isolate to trigger health checks
final class HeartbeatMessage {
  final DateTime timestamp;
  HeartbeatMessage(this.timestamp);
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
