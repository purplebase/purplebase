/// Pool state model - single source of truth for all pool state
library;

import 'package:models/models.dart';

/// Timing and limit constants for the pool
abstract class PoolConstants {
  /// Timeout for WebSocket connection and ping operations
  static const relayTimeout = Duration(seconds: 5);

  /// Maximum delay between reconnection attempts
  static const maxReconnectDelay = Duration(seconds: 30);

  /// Initial delay for first reconnection attempt
  static const initialReconnectDelay = Duration(milliseconds: 100);

  /// Only ping if no activity for this duration
  /// Set to 55s (under 60s) to avoid silent closure by NAT gateways and cellular networks
  static const pingIdleThreshold = Duration(seconds: 55);

  /// Interval between health checks from main isolate
  static const healthCheckInterval = Duration(minutes: 1);

  /// Maximum reconnection attempts before marking relay as failed
  static const maxRetries = 20;

  /// Maximum log entries to keep
  static const maxLogEntries = 200;
}

/// Unified phase for a relay-subscription pair
enum RelaySubPhase {
  /// Not connected
  disconnected,

  /// Attempting to connect
  connecting,

  /// Connected, waiting for EOSE
  loading,

  /// Connected, EOSE received, receiving live events
  streaming,

  /// Backing off before retry
  waiting,

  /// Max retries exceeded
  failed,
}

/// Log entry severity level
enum LogLevel { info, warning, error }

/// A log entry for debugging and monitoring
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? subscriptionId;
  final String? relayUrl;
  final Exception? exception;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.subscriptionId,
    this.relayUrl,
    this.exception,
  });

  @override
  String toString() {
    final parts = <String>[
      '[$level] $message',
      if (subscriptionId != null) 'sub=$subscriptionId',
      if (relayUrl != null) 'relay=$relayUrl',
      if (exception != null) 'error=$exception',
    ];
    return parts.join(' ');
  }
}

/// State of a relay within a subscription
class RelaySubState {
  final RelaySubPhase phase;
  final DateTime? lastEventAt;

  /// When the current uninterrupted streaming session started (reset on disconnect)
  final DateTime? streamingSince;
  final int reconnectAttempts;
  final String? lastError;

  const RelaySubState({
    this.phase = RelaySubPhase.disconnected,
    this.lastEventAt,
    this.streamingSince,
    this.reconnectAttempts = 0,
    this.lastError,
  });

  RelaySubState copyWith({
    RelaySubPhase? phase,
    DateTime? lastEventAt,
    DateTime? streamingSince,
    int? reconnectAttempts,
    String? lastError,
    bool clearError = false,
    bool clearStreamingSince = false,
  }) {
    return RelaySubState(
      phase: phase ?? this.phase,
      lastEventAt: lastEventAt ?? this.lastEventAt,
      streamingSince: clearStreamingSince
          ? null
          : (streamingSince ?? this.streamingSince),
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

/// A subscription with per-relay state
class Subscription {
  final String id;
  final Request request;
  final bool stream;
  final DateTime startedAt;
  final Map<String, RelaySubState> relays;

  Subscription({
    required this.id,
    required this.request,
    required this.stream,
    required this.startedAt,
    required this.relays,
  });

  /// Number of relays currently streaming (connected + EOSE received)
  int get activeRelayCount =>
      relays.values.where((r) => r.phase == RelaySubPhase.streaming).length;

  /// Total number of target relays
  int get totalRelayCount => relays.length;

  /// Whether all relays have failed
  bool get allFailed =>
      totalRelayCount > 0 &&
      relays.values.every((r) => r.phase == RelaySubPhase.failed);

  /// Whether any relay is streaming
  bool get hasActiveRelay => activeRelayCount > 0;

  /// Whether all relays have received EOSE (streaming or failed)
  bool get allEoseReceived => relays.values.every(
    (r) =>
        r.phase == RelaySubPhase.streaming || r.phase == RelaySubPhase.failed,
  );

  /// Status text for UI display
  String get statusText {
    if (allFailed) return 'failed';
    return '$activeRelayCount/$totalRelayCount relays';
  }

  Subscription copyWith({
    Request? request,
    bool? stream,
    Map<String, RelaySubState>? relays,
  }) {
    return Subscription(
      id: id,
      request: request ?? this.request,
      stream: stream ?? this.stream,
      startedAt: startedAt,
      relays: relays ?? this.relays,
    );
  }

  /// Update a single relay's state
  Subscription updateRelay(String url, RelaySubState state) {
    return copyWith(relays: {...relays, url: state});
  }
}

/// Pool state - single source of truth
class PoolState {
  final Map<String, Subscription> subscriptions;
  final List<LogEntry> logs;

  PoolState({this.subscriptions = const {}, this.logs = const []});

  /// Get subscription by ID
  Subscription? operator [](String id) => subscriptions[id];

  /// Check if a subscription exists
  bool hasSubscription(String id) => subscriptions.containsKey(id);
}

/// Result of publishing an event to a relay
class PublishResult {
  final String eventId;
  final String relayUrl;
  final bool accepted;
  final String? message;

  const PublishResult({
    required this.eventId,
    required this.relayUrl,
    required this.accepted,
    this.message,
  });
}
