import 'package:models/models.dart';

import '../pool/pool_state.dart';

/// Base class for all messages sent from background isolate to main isolate.
sealed class IsolateNotification {
  final timestamp = DateTime.now();
}

/// Query results arriving from the pool (streaming or fetch callbacks).
final class QueryResultNotification extends IsolateNotification {
  final Request request;
  final Set<String> savedIds;

  QueryResultNotification({required this.request, required this.savedIds});
}

/// Pool state snapshot for the UI.
final class PoolStateNotification extends IsolateNotification {
  final PoolState poolState;
  PoolStateNotification(this.poolState);
}

/// Action type for heartbeat messages.
enum HeartbeatAction { healthCheck, connect, disconnect }

/// Heartbeat message from main isolate.
final class HeartbeatMessage {
  final DateTime timestamp;
  final HeartbeatAction action;
  final ConnectivityStatus? connectivity;

  HeartbeatMessage(
    this.timestamp, {
    this.action = HeartbeatAction.healthCheck,
    this.connectivity,
  });
}

/// Operations sent from main isolate to background isolate.
sealed class IsolateOperation {}

final class LocalQueryOp extends IsolateOperation {
  final Map<Request, LocalQueryArgs> args;
  LocalQueryOp(this.args);
}

final class LocalSaveOp extends IsolateOperation {
  final Set<Map<String, dynamic>> events;
  LocalSaveOp({required this.events});
}

final class LocalClearOp extends IsolateOperation {}

final class LocalDeleteOp extends IsolateOperation {
  final Set<String> eventIds;
  LocalDeleteOp({required this.eventIds});
}

final class LocalPruneOp extends IsolateOperation {
  final Duration? olderThan;
  LocalPruneOp({this.olderThan});
}

final class RemoteQueryOp extends IsolateOperation {
  final Request req;
  final RemoteSource source;
  RemoteQueryOp({required this.req, required this.source});
}

final class RemotePublishOp extends IsolateOperation {
  final List<Map<String, dynamic>> events;
  final Set<String> relays;
  RemotePublishOp({required this.events, required this.relays});
}

/// Cancel a subscription on the isolate-side relay pool.
///
/// Carries only the [subscriptionId] (a `String`) instead of the full
/// `Request`. A `Request` holds `RequestFilter`s whose client-side
/// fields (`where`, `and`, `schemaFilter`) are nullable closures —
/// when the request was built inside a Flutter widget's `build` method
/// those closures capture the enclosing closure context, which can
/// transitively reach the live widget tree (e.g. `RenderParagraph` →
/// `WidgetsFlutterBinding`). Sending such an object across an isolate
/// boundary throws `IsolateException: object is unsendable`.
///
/// Cancellation needs nothing but the subscription ID, so we send only
/// that. See `RelayPool.unsubscribeById`.
final class RemoteCancelOp extends IsolateOperation {
  final String subscriptionId;
  RemoteCancelOp({required this.subscriptionId});
}

final class CloseSubscriptionsOp extends IsolateOperation {
  final Set<String> relayUrls;
  CloseSubscriptionsOp({required this.relayUrls});
}

final class CloseIsolateOp extends IsolateOperation {}

/// Query arguments for local database operations.
class LocalQueryArgs {
  final List<String> queries;
  final List<Map<String, dynamic>> params;

  LocalQueryArgs({required this.queries, required this.params}) {
    if (queries.length != params.length) {
      throw Exception('Bad amount of arguments');
    }
  }

  factory LocalQueryArgs.fromPairs(
      List<(String, Map<String, dynamic>)> pairs) {
    final queries = pairs.map((q) => q.$1).toList();
    final params = pairs.map((q) => q.$2).toList();
    return LocalQueryArgs(queries: queries, params: params);
  }
}

/// Response from isolate.
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
