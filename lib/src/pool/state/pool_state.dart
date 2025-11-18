import 'dart:convert';

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

  /// Get relays that have sent EOSE for a subscription
  Set<String> getRelaysWithEose(String subscriptionId) {
    final sub = subscriptions[subscriptionId];
    if (sub == null) return {};

    return sub.targetRelays.where((url) {
      return sub.relayStatus[url]?.eoseReceivedAt != null;
    }).toSet();
  }

  /// Get relays waiting for EOSE for a subscription
  Set<String> getRelaysWaitingForEose(String subscriptionId) {
    final sub = subscriptions[subscriptionId];
    if (sub == null) return {};

    return sub.targetRelays.where((url) {
      return sub.relayStatus[url]?.eoseReceivedAt == null;
    }).toSet();
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

  /// Request filters for this subscription (for UI display)
  final List<Map<String, dynamic>> filters;

  SubscriptionState({
    required this.subscriptionId,
    required this.targetRelays,
    required this.isStreaming,
    required this.relayStatus,
    required this.phase,
    required this.startedAt,
    this.totalEventsReceived = 0,
    this.filters = const [],
  });

  SubscriptionState copyWith({
    String? subscriptionId,
    Set<String>? targetRelays,
    bool? isStreaming,
    Map<String, RelaySubscriptionStatus>? relayStatus,
    SubscriptionPhase? phase,
    DateTime? startedAt,
    int? totalEventsReceived,
    List<Map<String, dynamic>>? filters,
  }) {
    return SubscriptionState(
      subscriptionId: subscriptionId ?? this.subscriptionId,
      targetRelays: targetRelays ?? this.targetRelays,
      isStreaming: isStreaming ?? this.isStreaming,
      relayStatus: relayStatus ?? this.relayStatus,
      phase: phase ?? this.phase,
      startedAt: startedAt ?? this.startedAt,
      totalEventsReceived: totalEventsReceived ?? this.totalEventsReceived,
      filters: filters ?? this.filters,
    );
  }
}

/// How is this subscription doing on a specific relay?
class RelaySubscriptionStatus {
  final RelaySubscriptionPhase phase;
  final DateTime? eoseReceivedAt;
  final int reconnectionAttempts;
  final DateTime? lastReconnectAt;

  /// The actual filters sent to this relay (for debugging/inspection)
  /// Private - use getReqMessage() to access the actual REQ
  final List<Map<String, dynamic>>? _filters;

  RelaySubscriptionStatus({
    required this.phase,
    this.eoseReceivedAt,
    this.reconnectionAttempts = 0,
    this.lastReconnectAt,
    List<Map<String, dynamic>>? filters,
  }) : _filters = filters;

  /// Get the actual REQ message sent to this relay as a JSON string
  /// This is the ONLY way to access what was actually sent to the relay
  String? getReqMessage(String subscriptionId) {
    if (_filters == null) return null;
    return jsonEncode(['REQ', subscriptionId, ..._filters]);
  }

  RelaySubscriptionStatus copyWith({
    RelaySubscriptionPhase? phase,
    DateTime? eoseReceivedAt,
    int? reconnectionAttempts,
    DateTime? lastReconnectAt,
    List<Map<String, dynamic>>? filters,
  }) {
    return RelaySubscriptionStatus(
      phase: phase ?? this.phase,
      eoseReceivedAt: eoseReceivedAt ?? this.eoseReceivedAt,
      reconnectionAttempts: reconnectionAttempts ?? this.reconnectionAttempts,
      lastReconnectAt: lastReconnectAt ?? this.lastReconnectAt,
      filters: filters ?? _filters,
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
  final int connectingCount;

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
    required this.connectingCount,
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
      connectingCount: 0,
      totalSubscriptions: 0,
      fullyActiveSubscriptions: 0,
      partiallyActiveSubscriptions: 0,
      failedSubscriptions: 0,
    );
  }
}

/// Extensions to help display and understand pool state in UI
extension PoolStateDisplay on PoolState {
  /// Groups subscriptions by their prefix to identify related subscriptions
  /// Useful for debugging multiple subscriptions with same prefix
  Map<String, List<SubscriptionState>> subscriptionsByPrefix() {
    final grouped = <String, List<SubscriptionState>>{};

    for (final sub in subscriptions.values) {
      // Extract prefix (everything before last dash)
      final lastDash = sub.subscriptionId.lastIndexOf('-');
      final prefix = lastDash != -1
          ? sub.subscriptionId.substring(0, lastDash)
          : sub.subscriptionId;

      grouped.putIfAbsent(prefix, () => []).add(sub);
    }

    return grouped;
  }

  /// Get a human-readable summary of subscription state
  String subscriptionSummary() {
    final byPrefix = subscriptionsByPrefix();
    final buffer = StringBuffer();

    buffer.writeln('Active Subscriptions: ${subscriptions.length}');
    buffer.writeln('Unique Prefixes: ${byPrefix.length}');
    buffer.writeln();

    for (final entry in byPrefix.entries) {
      buffer.writeln('Prefix: ${entry.key}');
      buffer.writeln('  Count: ${entry.value.length} subscription(s)');

      for (final sub in entry.value) {
        buffer.writeln('  - ${sub.subscriptionId}');
        buffer.writeln('    Relays: ${sub.targetRelays.length}');
        buffer.writeln('    Streaming: ${sub.isStreaming}');
        buffer.writeln('    Events: ${sub.totalEventsReceived}');
        buffer.writeln('    Filters: ${sub.filters.length}');
        if (sub.filters.isNotEmpty) {
          for (var i = 0; i < sub.filters.length; i++) {
            buffer.writeln('      [$i] ${sub.filters[i]}');
          }
        }
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// Get detailed info about a specific subscription for debugging
  String subscriptionDetails(String subscriptionId) {
    final sub = subscriptions[subscriptionId];
    if (sub == null) return 'Subscription $subscriptionId not found';

    final buffer = StringBuffer();
    buffer.writeln('Subscription: ${sub.subscriptionId}');
    buffer.writeln('Started: ${sub.startedAt}');
    buffer.writeln('Phase: ${sub.phase}');
    buffer.writeln('Streaming: ${sub.isStreaming}');
    buffer.writeln('Events Received: ${sub.totalEventsReceived}');
    buffer.writeln('Target Relays: ${sub.targetRelays.length}');
    buffer.writeln();

    buffer.writeln('Filters (${sub.filters.length}):');
    for (var i = 0; i < sub.filters.length; i++) {
      buffer.writeln('  [$i] ${sub.filters[i]}');
    }
    buffer.writeln();

    buffer.writeln('Relay Status:');
    for (final url in sub.targetRelays) {
      final status = sub.relayStatus[url];
      final conn = connections[url];
      final hasEose = status?.eoseReceivedAt != null;
      buffer.writeln('  $url:');
      buffer.writeln('    Connection: ${conn?.phase.runtimeType ?? "unknown"}');
      buffer.writeln(
        '    Subscription: ${status?.phase.runtimeType ?? "unknown"}',
      );
      buffer.writeln(
        '    EOSE: ${hasEose ? "✓ received at ${status!.eoseReceivedAt}" : "✗ waiting"}',
      );
      final reqMsg = status?.getReqMessage(sub.subscriptionId);
      if (reqMsg != null) {
        buffer.writeln('    Actual REQ: $reqMsg');
      }
    }

    buffer.writeln();
    final withEose = getRelaysWithEose(subscriptionId);
    final waitingForEose = getRelaysWaitingForEose(subscriptionId);
    buffer.writeln(
      'EOSE Summary: ${withEose.length}/${sub.targetRelays.length} relays',
    );
    if (waitingForEose.isNotEmpty) {
      buffer.writeln('Still waiting for: ${waitingForEose.join(", ")}');
    }

    return buffer.toString();
  }
}
