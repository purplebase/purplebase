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
    mainSendPort.send(InfoMessage('ERROR: Failed to open database - $e'));
  }

  // Listen for messages from websocket pool
  closeFn = pool.addListener((response) {
    if (response case EventRelayResponse(
      :final req,
      :final events,
      :final relaysForIds,
    )) {
      final ids = db!.save(events, relaysForIds, config);
      mainSendPort.send(QueryResultMessage(request: req, savedIds: ids));
    }
  });

  // Add info listener for websocket pool
  pool.addInfoListener((message) {
    mainSendPort.send(InfoMessage(message));
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

            // Count events by kind
            final kindCounts = <int, int>{};
            var totalEvents = 0;

            for (final events in result.values) {
              for (final event in events) {
                totalEvents++;
                final kind = event['kind'] as int? ?? -1;
                kindCounts[kind] = (kindCounts[kind] ?? 0) + 1;
              }
            }

            final kindSummary = kindCounts.entries
                .map((e) => 'kind ${e.key}: ${e.value}')
                .join(', ');

            mainSendPort.send(
              InfoMessage(
                'Local query completed: ${result.length} request(s) processed, $totalEvents events returned ($kindSummary)',
              ),
            );
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
            mainSendPort.send(InfoMessage('ERROR: Local query failed - $e'));
          }

        case LocalSaveIsolateOperation(:final events):
          try {
            final ids = db!.save(events, {}, config);
            response = IsolateResponse(success: true, result: ids);
            mainSendPort.send(
              InfoMessage(
                'Local save completed: ${ids.length} event(s) saved [${ids.take(10).join(', ')}${ids.length > 10 ? '...' : ''}]',
              ),
            );
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
          final relayUrls = config.getRelays(source: source, useDefault: true);
          final future = pool.query(req, relayUrls: relayUrls);
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
          final relayUrls = config.getRelays(source: source, useDefault: true);
          mainSendPort.send(
            InfoMessage(
              'Publishing ${events.length} event(s) to ${relayUrls.length} relay(s) [${relayUrls.join(', ')}]',
            ),
          );
          final result = await pool.publish(events, relayUrls: relayUrls);
          response = IsolateResponse(success: true, result: result);

        case RemoteCancelIsolateOperation(:final req):
          pool.unsubscribe(req);
          response = IsolateResponse(success: true);
          mainSendPort.send(
            InfoMessage('Remote subscription cancelled: ${req.subscriptionId}'),
          );

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
