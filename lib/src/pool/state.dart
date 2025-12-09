/// Simplified pool state for UI observation
/// Merged state + debug: state changes include reason strings
library;

/// Connection status enum
enum ConnectionStatus { disconnected, connecting, connected }

/// Immutable snapshot of pool state for UI
class PoolState {
  /// Per-relay connection state
  final Map<String, RelayState> relays;

  /// Per-subscription request state
  final Map<String, RequestState> requests;

  /// When this snapshot was created
  final DateTime timestamp;

  /// Last state change description (merged debug info)
  /// Examples: "Connected to wss://...", "Reconnecting (attempt 2)"
  final String? lastChange;

  const PoolState({
    this.relays = const {},
    this.requests = const {},
    required this.timestamp,
    this.lastChange,
  });

  factory PoolState.initial() => PoolState(timestamp: DateTime.now());

  PoolState copyWith({
    Map<String, RelayState>? relays,
    Map<String, RequestState>? requests,
    DateTime? timestamp,
    String? lastChange,
  }) {
    return PoolState(
      relays: relays ?? this.relays,
      requests: requests ?? this.requests,
      timestamp: timestamp ?? this.timestamp,
      lastChange: lastChange,
    );
  }

  // Convenience getters

  int get connectedCount =>
      relays.values.where((r) => r.status == ConnectionStatus.connected).length;

  int get disconnectedCount =>
      relays.values
          .where((r) => r.status == ConnectionStatus.disconnected)
          .length;

  int get connectingCount =>
      relays.values
          .where((r) => r.status == ConnectionStatus.connecting)
          .length;

  bool isRelayConnected(String url) =>
      relays[url]?.status == ConnectionStatus.connected;
}

/// Per-relay connection state
class RelayState {
  final String url;
  final ConnectionStatus status;
  final int reconnectAttempts;
  final String? error;
  final DateTime? lastActivityAt;
  final DateTime statusChangedAt;

  const RelayState({
    required this.url,
    required this.status,
    this.reconnectAttempts = 0,
    this.error,
    this.lastActivityAt,
    required this.statusChangedAt,
  });

  RelayState copyWith({
    ConnectionStatus? status,
    int? reconnectAttempts,
    String? error,
    DateTime? lastActivityAt,
    DateTime? statusChangedAt,
  }) {
    return RelayState(
      url: url,
      status: status ?? this.status,
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      error: error ?? this.error,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      statusChangedAt: statusChangedAt ?? this.statusChangedAt,
    );
  }
}

/// Per-subscription request state
class RequestState {
  final String subscriptionId;
  final List<Map<String, dynamic>> filters;
  final Set<String> targetRelays;
  final Set<String> eoseReceived;
  final bool isStreaming;
  final int eventCount;
  final DateTime startedAt;

  const RequestState({
    required this.subscriptionId,
    required this.filters,
    required this.targetRelays,
    this.eoseReceived = const {},
    this.isStreaming = false,
    this.eventCount = 0,
    required this.startedAt,
  });

  RequestState copyWith({
    List<Map<String, dynamic>>? filters,
    Set<String>? targetRelays,
    Set<String>? eoseReceived,
    bool? isStreaming,
    int? eventCount,
  }) {
    return RequestState(
      subscriptionId: subscriptionId,
      filters: filters ?? this.filters,
      targetRelays: targetRelays ?? this.targetRelays,
      eoseReceived: eoseReceived ?? this.eoseReceived,
      isStreaming: isStreaming ?? this.isStreaming,
      eventCount: eventCount ?? this.eventCount,
      startedAt: startedAt,
    );
  }

  /// Status text for UI: "2/3 EOSE" or "streaming"
  String get statusText {
    if (isStreaming && eoseReceived.length == targetRelays.length) {
      return 'streaming';
    }
    return '${eoseReceived.length}/${targetRelays.length} EOSE';
  }

  /// Whether all target relays have sent EOSE
  bool get allEoseReceived =>
      targetRelays.isNotEmpty && eoseReceived.containsAll(targetRelays);
}

