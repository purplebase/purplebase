import 'package:purplebase/src/websocket_pool.dart';

/// Comprehensive data about relay connections and active requests
final class RelayStatusData {
  final Map<String, RelayConnectionInfo> relays;
  final Map<String, ActiveRequestInfo> activeRequests;
  final Map<String, PublishRequestInfo> publishRequests;

  RelayStatusData({
    required this.relays,
    required this.activeRequests,
    required this.publishRequests,
  });
}

/// Information about a single relay connection
final class RelayConnectionInfo {
  final String url;
  final RelayConnectionState state;
  final DateTime? lastActivity;
  final int reconnectAttempts;

  RelayConnectionInfo({
    required this.url,
    required this.state,
    this.lastActivity,
    required this.reconnectAttempts,
  });
}

/// Information about an active subscription request
final class ActiveRequestInfo {
  final String subscriptionId;
  final Set<String> targetRelays;
  final Set<String> connectedRelays;
  final Set<String> eoseReceived;
  final SubscriptionPhase phase;
  final DateTime startTime;

  ActiveRequestInfo({
    required this.subscriptionId,
    required this.targetRelays,
    required this.connectedRelays,
    required this.eoseReceived,
    required this.phase,
    required this.startTime,
  });
}

/// Information about a publish request
final class PublishRequestInfo {
  final String id;
  final List<String> targetRelays;
  final Map<String, bool> relayResults; // true = success, false = failed
  final DateTime startTime;

  PublishRequestInfo({
    required this.id,
    required this.targetRelays,
    required this.relayResults,
    required this.startTime,
  });
}

/// Connection state of a relay
enum RelayConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}
