import 'package:purplebase/src/pool/state/connection_phase.dart';
import 'package:purplebase/src/pool/state/subscription_phase.dart';

/// Single comprehensive snapshot of WebSocket pool state
/// Replaces: PoolStatus + InfoMessage + error logs
/// Clients can record emitted states over time if history is needed
class PoolState {
  /// Connection state for each relay URL
  final Map<String, RelayConnectionState> connections;

  /// Subscription state for each subscription ID
  final Map<String, SubscriptionState> subscriptions;

  /// Active publish operations
  final Map<String, PublishOperation> publishes;

  /// Health metrics (at-a-glance debugging)
  final HealthMetrics health;

  /// When this state snapshot was created
  final DateTime timestamp;

  PoolState({
    required this.connections,
    required this.subscriptions,
    required this.publishes,
    required this.health,
    required this.timestamp,
  });

  /// Create an empty initial state
  factory PoolState.initial() {
    return PoolState(
      connections: {},
      subscriptions: {},
      publishes: {},
      health: HealthMetrics.empty(),
      timestamp: DateTime.now(),
    );
  }

  PoolState copyWith({
    Map<String, RelayConnectionState>? connections,
    Map<String, SubscriptionState>? subscriptions,
    Map<String, PublishOperation>? publishes,
    HealthMetrics? health,
    DateTime? timestamp,
  }) {
    return PoolState(
      connections: connections ?? this.connections,
      subscriptions: subscriptions ?? this.subscriptions,
      publishes: publishes ?? this.publishes,
      health: health ?? this.health,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  // Convenience query methods

  /// Check if relay is connected
  bool isRelayConnected(String relayUrl) {
    final phase = connections[relayUrl]?.phase;
    return phase is Connected;
  }

  /// Check if subscription is fully active (all target relays connected)
  bool isSubscriptionFullyActive(String subscriptionId) {
    final sub = subscriptions[subscriptionId];
    if (sub == null) return false;

    return sub.targetRelays.every((url) {
      final status = sub.relayStatus[url];
      return status?.phase is SubscriptionActive && isRelayConnected(url);
    });
  }

  /// Get number of active relays for a subscription
  int getActiveRelayCount(String subscriptionId) {
    final sub = subscriptions[subscriptionId];
    if (sub == null) return 0;

    return sub.targetRelays.where((url) {
      final status = sub.relayStatus[url];
      return status?.phase is SubscriptionActive && isRelayConnected(url);
    }).length;
  }
}

/// Per-relay connection state - explicit state machine
class RelayConnectionState {
  final String url;
  final ConnectionPhase phase; // The actual state
  final DateTime phaseStartedAt;
  final int reconnectAttempts;
  final DateTime? lastMessageAt;
  final String? lastError;

  /// Subscription IDs this relay is serving
  final Set<String> activeSubscriptionIds;

  RelayConnectionState({
    required this.url,
    required this.phase,
    required this.phaseStartedAt,
    this.reconnectAttempts = 0,
    this.lastMessageAt,
    this.lastError,
    Set<String>? activeSubscriptionIds,
  }) : activeSubscriptionIds = activeSubscriptionIds ?? {};

  RelayConnectionState copyWith({
    String? url,
    ConnectionPhase? phase,
    DateTime? phaseStartedAt,
    int? reconnectAttempts,
    DateTime? lastMessageAt,
    String? lastError,
    Set<String>? activeSubscriptionIds,
  }) {
    return RelayConnectionState(
      url: url ?? this.url,
      phase: phase ?? this.phase,
      phaseStartedAt: phaseStartedAt ?? this.phaseStartedAt,
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastError: lastError ?? this.lastError,
      activeSubscriptionIds:
          activeSubscriptionIds ?? this.activeSubscriptionIds,
    );
  }
}

/// Per-subscription state
class SubscriptionState {
  final String subscriptionId;
  final Set<String> targetRelays;
  final bool isStreaming;

  /// Per-relay status within this subscription
  final Map<String, RelaySubscriptionStatus> relayStatus;

  final SubscriptionPhase phase; // eose vs streaming
  final DateTime startedAt;
  final int totalEventsReceived;

  SubscriptionState({
    required this.subscriptionId,
    required this.targetRelays,
    required this.isStreaming,
    required this.relayStatus,
    required this.phase,
    required this.startedAt,
    this.totalEventsReceived = 0,
  });

  SubscriptionState copyWith({
    String? subscriptionId,
    Set<String>? targetRelays,
    bool? isStreaming,
    Map<String, RelaySubscriptionStatus>? relayStatus,
    SubscriptionPhase? phase,
    DateTime? startedAt,
    int? totalEventsReceived,
  }) {
    return SubscriptionState(
      subscriptionId: subscriptionId ?? this.subscriptionId,
      targetRelays: targetRelays ?? this.targetRelays,
      isStreaming: isStreaming ?? this.isStreaming,
      relayStatus: relayStatus ?? this.relayStatus,
      phase: phase ?? this.phase,
      startedAt: startedAt ?? this.startedAt,
      totalEventsReceived: totalEventsReceived ?? this.totalEventsReceived,
    );
  }
}

/// How is this subscription doing on a specific relay?
class RelaySubscriptionStatus {
  final RelaySubscriptionPhase phase;
  final DateTime? eoseReceivedAt;
  final int reconnectionAttempts;
  final DateTime? lastReconnectAt;

  RelaySubscriptionStatus({
    required this.phase,
    this.eoseReceivedAt,
    this.reconnectionAttempts = 0,
    this.lastReconnectAt,
  });

  RelaySubscriptionStatus copyWith({
    RelaySubscriptionPhase? phase,
    DateTime? eoseReceivedAt,
    int? reconnectionAttempts,
    DateTime? lastReconnectAt,
  }) {
    return RelaySubscriptionStatus(
      phase: phase ?? this.phase,
      eoseReceivedAt: eoseReceivedAt ?? this.eoseReceivedAt,
      reconnectionAttempts: reconnectionAttempts ?? this.reconnectionAttempts,
      lastReconnectAt: lastReconnectAt ?? this.lastReconnectAt,
    );
  }
}

/// Publish operation state
class PublishOperation {
  final String id;
  final Set<String> targetRelays;
  final Map<String, bool> relayResults; // relay -> accepted
  final DateTime startedAt;

  PublishOperation({
    required this.id,
    required this.targetRelays,
    required this.relayResults,
    required this.startedAt,
  });
}

/// Health metrics (at a glance debugging)
class HealthMetrics {
  final int totalConnections;
  final int connectedCount;
  final int disconnectedCount;
  final int reconnectingCount;

  final int totalSubscriptions;
  final int fullyActiveSubscriptions;
  final int partiallyActiveSubscriptions;
  final int failedSubscriptions;

  final DateTime? lastHealthCheckAt;
  final Duration? timeSinceLastActivity;
  final bool systemSuspicionDetected;

  HealthMetrics({
    required this.totalConnections,
    required this.connectedCount,
    required this.disconnectedCount,
    required this.reconnectingCount,
    required this.totalSubscriptions,
    required this.fullyActiveSubscriptions,
    required this.partiallyActiveSubscriptions,
    required this.failedSubscriptions,
    this.lastHealthCheckAt,
    this.timeSinceLastActivity,
    this.systemSuspicionDetected = false,
  });

  factory HealthMetrics.empty() {
    return HealthMetrics(
      totalConnections: 0,
      connectedCount: 0,
      disconnectedCount: 0,
      reconnectingCount: 0,
      totalSubscriptions: 0,
      fullyActiveSubscriptions: 0,
      partiallyActiveSubscriptions: 0,
      failedSubscriptions: 0,
    );
  }
}


