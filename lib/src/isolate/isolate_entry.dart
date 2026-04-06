import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import '../db/codec.dart';
import '../db/database.dart';
import '../db/pruning.dart';
import '../pool/relay_pool.dart';
import 'messages.dart';

/// Background isolate entry point.
///
/// Initializes the database and relay pool, then listens for operations
/// from the main isolate via typed messages.
void isolateEntryPoint(List args) {
  final [
    SendPort mainSendPort,
    StorageConfiguration config,
    Verifier verifier,
  ] = args;

  final receivePort = ReceivePort();
  StreamSubscription? sub;

  // Track which subscriptions should send QueryResultNotification
  final Set<String> callbackSubscriptions = {};

  Database? db;
  try {
    if (config.databasePath != null) {
      final dirPath = path.join(Directory.current.path, config.databasePath);
      db = sqlite3.open(dirPath);
    } else {
      db = sqlite3.openInMemory();
    }
    db.initialize();
  } catch (_) {
    return;
  }

  final pool = RelayPool(
    config: config,
    onStateChange: (state) {
      mainSendPort.send(PoolStateNotification(state));
    },
    onEvents: ({
      required Request req,
      required List<Map<String, dynamic>> events,
      required Map<String, Set<String>> relaysForIds,
    }) {
      if (events.isEmpty) return;

      final ids = db!.save(events.toSet(), relaysForIds, config, verifier);

      // Delete events rejected by schemaFilter
      final schemaFilters = req.filters
          .map((f) => f.schemaFilter)
          .whereType<SchemaFilter>()
          .toList();

      if (schemaFilters.isNotEmpty && ids.isNotEmpty) {
        final rejectedIds = <String>{};
        for (final event in events) {
          final eventId = event['id'] as String?;
          if (eventId == null || !ids.contains(eventId)) continue;
          final passesAll = schemaFilters.every((filter) => filter(event));
          if (!passesAll) {
            rejectedIds.add(eventId);
          }
        }
        if (rejectedIds.isNotEmpty) {
          db.deleteEvents(rejectedIds);
          ids.removeAll(rejectedIds);
        }
      }

      if (callbackSubscriptions.contains(req.subscriptionId)) {
        mainSendPort
            .send(QueryResultNotification(request: req, savedIds: ids));
      }
    },
  );

  mainSendPort.send(receivePort.sendPort);

  sub = receivePort.listen((message) async {
    // Handle heartbeat messages
    if (message is HeartbeatMessage) {
      try {
        switch (message.action) {
          case HeartbeatAction.connect:
            pool.connect();
          case HeartbeatAction.disconnect:
            pool.disconnect();
          case HeartbeatAction.healthCheck:
            // Forward connectivity status to pool
            if (message.connectivity != null) {
              pool.setConnectivity(
                  message.connectivity == ConnectivityStatus.online);
            }
            await pool.performHealthCheck();
        }
      } catch (_) {
        // Errors are logged in pool state
      }
      return;
    }

    if (message
        case (
          final IsolateOperation operation,
          final SendPort replyPort,
        )) {
      IsolateResponse response;

      switch (operation) {
        // LOCAL STORAGE

        case LocalQueryOp(:final args):
          try {
            final result = db!.find(args);
            response = IsolateResponse(success: true, result: result);
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
          }

        case LocalSaveOp(:final events):
          try {
            final ids = db!.save(events, {}, config, verifier);
            response = IsolateResponse(success: true, result: ids);
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
          }

        case LocalClearOp():
          try {
            db!.initialize(clear: true);
            response = IsolateResponse(success: true);
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
          }

        case LocalDeleteOp(:final eventIds):
          try {
            db!.deleteEvents(eventIds);
            response = IsolateResponse(success: true);
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
          }

        case LocalPruneOp(:final olderThan):
          try {
            final age = olderThan ?? const Duration(days: 30);
            final database = db!;
            final deleted = database.prune(age);
            database.walCheckpoint();
            response = IsolateResponse(success: true, result: deleted);
          } catch (e) {
            response = IsolateResponse(success: false, error: e.toString());
          }

        // REMOTE

        case RemoteQueryOp(:final req, :final source):
          if (source.stream) {
            callbackSubscriptions.add(req.subscriptionId);
          }

          final result = await pool.query(req, source: source);
          response = IsolateResponse(
              success: true, result: EventCodec.decode(result));

        case RemotePublishOp(:final events, :final relays):
          final result = await pool.publish(events, relays: relays);
          response = IsolateResponse(success: true, result: result);

        case RemoteCancelOp(:final req):
          pool.unsubscribe(req);
          callbackSubscriptions.remove(req.subscriptionId);
          response = IsolateResponse(success: true);

        case CloseSubscriptionsOp(:final relayUrls):
          final cancelledSubIds = pool.closeSubscriptionsToRelays(relayUrls);
          for (final subId in cancelledSubIds) {
            callbackSubscriptions.remove(subId);
          }
          response = IsolateResponse(success: true);

        // ISOLATE

        case CloseIsolateOp():
          db?.dispose();
          pool.dispose();
          response = IsolateResponse(success: true);
          Future.microtask(() => sub?.cancel());
      }

      replyPort.send(response);
    }
  });
}
