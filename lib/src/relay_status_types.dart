import 'package:purplebase/src/websocket_pool.dart';

/// Comprehensive status of the WebSocket pool operations
final class PoolStatus {
  final Map<String, RelayConnectionInfo> connections;
  final Map<String, SubscriptionInfo> subscriptions;
  final Map<String, PublishInfo> publishes;
  final List<ErrorEntry> recentErrors;
  final DateTime lastUpdated;

  PoolStatus({
    required this.connections,
    required this.subscriptions,
    required this.publishes,
    required this.recentErrors,
    required this.lastUpdated,
  });

  PoolStatus copyWith({
    Map<String, RelayConnectionInfo>? connections,
    Map<String, SubscriptionInfo>? subscriptions,
    Map<String, PublishInfo>? publishes,
    List<ErrorEntry>? recentErrors,
    DateTime? lastUpdated,
  }) => PoolStatus(
    connections: connections ?? this.connections,
    subscriptions: subscriptions ?? this.subscriptions,
    publishes: publishes ?? this.publishes,
    recentErrors: recentErrors ?? this.recentErrors,
    lastUpdated: lastUpdated ?? this.lastUpdated,
  );

  // Convenience methods for querying status

  /// Get relay connection state (null if relay not tracked)
  RelayConnectionState? getRelayState(String relayUrl) {
    return connections[relayUrl]?.state;
  }

  /// Check if relay is connected (connected or reconnected)
  bool isRelayConnected(String relayUrl) {
    final state = connections[relayUrl]?.state;
    return state == RelayConnectionState.connected ||
        state == RelayConnectionState.reconnected;
  }

  /// Check if relay has reconnected (not initial connection)
  bool hasRelayReconnected(String relayUrl) {
    return connections[relayUrl]?.state == RelayConnectionState.reconnected;
  }

  /// Get when relay state last changed
  DateTime? getRelayLastStatusChange(String relayUrl) {
    return connections[relayUrl]?.lastStatusChange;
  }

  /// Check if subscription is active on a specific relay
  bool isSubscriptionActiveOn(String subscriptionId, String relayUrl) {
    final sub = subscriptions[subscriptionId];
    if (sub == null) return false;
    return sub.connectedRelays.contains(relayUrl) && isRelayConnected(relayUrl);
  }

  /// Get number of active relays for a subscription
  int getActiveRelayCount(String subscriptionId) {
    final sub = subscriptions[subscriptionId];
    if (sub == null) return 0;
    return sub.connectedRelays.where((url) => isRelayConnected(url)).length;
  }

  /// Check if subscription is fully active (all target relays connected)
  bool isSubscriptionFullyActive(String subscriptionId) {
    final sub = subscriptions[subscriptionId];
    if (sub == null) return false;
    return sub.connectedRelays.length == sub.targetRelays.length &&
        sub.connectedRelays.every((url) => isRelayConnected(url));
  }

  /// Get list of all connected relay URLs
  List<String> get connectedRelayUrls {
    return connections.entries
        .where(
          (e) =>
              e.value.state == RelayConnectionState.connected ||
              e.value.state == RelayConnectionState.reconnected,
        )
        .map((e) => e.key)
        .toList();
  }

  /// Get list of all disconnected relay URLs
  List<String> get disconnectedRelayUrls {
    return connections.entries
        .where((e) => e.value.state == RelayConnectionState.disconnected)
        .map((e) => e.key)
        .toList();
  }
}

/// Error entry in the circular buffer
final class ErrorEntry {
  final DateTime timestamp;
  final String message;
  final String? relayUrl;
  final String? subscriptionId;
  final String? eventId;

  ErrorEntry({
    required this.timestamp,
    required this.message,
    this.relayUrl,
    this.subscriptionId,
    this.eventId,
  });
}

/// Legacy type alias for backward compatibility
typedef RelayStatusData = PoolStatus;

/// Information about a single relay connection
final class RelayConnectionInfo {
  final String url;
  final RelayConnectionState state;
  final DateTime? lastActivity;
  final int reconnectAttempts;
  final DateTime lastStatusChange; // When state last changed

  RelayConnectionInfo({
    required this.url,
    required this.state,
    this.lastActivity,
    required this.reconnectAttempts,
    required this.lastStatusChange,
  });
}

/// Information about an active subscription request
final class SubscriptionInfo {
  final String subscriptionId;
  final Set<String> targetRelays;
  final Set<String>
  connectedRelays; // Relays where this request is currently active
  final Set<String> eoseReceived;
  final SubscriptionPhase phase;
  final DateTime startTime;
  final List<Map<String, dynamic>>?
  requestFilters; // List to support multiple filters

  /// Number of times each relay has reconnected for this subscription
  final Map<String, int> reconnectionCount;

  /// Timestamp of last reconnection for each relay
  final Map<String, DateTime> lastReconnectTime;

  /// Relays currently re-syncing after reconnection
  final Set<String> resyncing;

  SubscriptionInfo({
    required this.subscriptionId,
    required this.targetRelays,
    required this.connectedRelays,
    required this.eoseReceived,
    required this.phase,
    required this.startTime,
    this.requestFilters,
    this.reconnectionCount = const {},
    this.lastReconnectTime = const {},
    this.resyncing = const {},
  });
}

/// Information about a publish request
final class PublishInfo {
  final String id;
  final List<String> targetRelays;
  final Map<String, bool> relayResults;
  final DateTime startTime;

  PublishInfo({
    required this.id,
    required this.targetRelays,
    required this.relayResults,
    required this.startTime,
  });
}

/// Legacy type aliases for backward compatibility
typedef ActiveRequestInfo = SubscriptionInfo;
typedef PublishRequestInfo = PublishInfo;

/// Connection state of a relay (simplified)
enum RelayConnectionState {
  disconnected,
  connecting,
  connected,
  reconnected, // Relay reconnected after being connected before
}
