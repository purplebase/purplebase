/// Pool state model - single source of truth for all pool state
library;

import 'package:models/models.dart';

/// Timing and limit constants for the pool
abstract class PoolConstants {
  /// Timeout for WebSocket connection and ping operations
  static const relayTimeout = Duration(seconds: 5);

  /// Only ping if no activity for this duration
  /// Set to 55s (under 60s) to avoid silent closure by NAT gateways and cellular networks
  static const pingIdleThreshold = Duration(seconds: 55);

  /// Interval between health checks from main isolate
  static const healthCheckInterval = Duration(minutes: 1);

  /// Maximum log entries to keep
  static const maxLogEntries = 200;

  /// Maximum closed subscriptions to keep in history
  static const maxClosedSubscriptions = 200;

  /// Backoff schedule: delay = 2^n seconds, repeated 2^n times
  /// n=0: 1s × 1, n=1: 2s × 2, n=2: 4s × 4, n=3: 8s × 8, n=4: 16s × 16
  /// Total: 1 + 2 + 4 + 8 + 16 = 31 attempts, then fail
  static const _maxBackoffLevel = 4; // max delay = 2^4 = 16 seconds

  /// Total attempts before failure: sum of 2^n for n=0..4 = 31
  static const maxRetries = 31;

  /// Get the backoff delay for a given attempt number (1-based)
  /// Returns null if attempts exceed maxRetries (should fail)
  static Duration? getBackoffDelay(int attempt) {
    if (attempt < 1 || attempt > maxRetries) return null;

    // Find which level this attempt belongs to
    // Level 0: attempts 1 (1 attempt)
    // Level 1: attempts 2-3 (2 attempts)
    // Level 2: attempts 4-7 (4 attempts)
    // Level 3: attempts 8-15 (8 attempts)
    // Level 4: attempts 16-31 (16 attempts)
    var cumulativeAttempts = 0;
    for (var n = 0; n <= _maxBackoffLevel; n++) {
      final attemptsAtLevel = 1 << n; // 2^n
      cumulativeAttempts += attemptsAtLevel;
      if (attempt <= cumulativeAttempts) {
        final delaySeconds = 1 << n; // 2^n seconds
        return Duration(seconds: delaySeconds);
      }
    }
    return null; // Should not reach here
  }
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

  /// Subscription completed/closed (non-streaming finished or manually unsubscribed)
  closed,
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
class RelaySubscription {
  final String id;
  final Request request;
  final bool stream;
  final DateTime startedAt;
  final DateTime? closedAt;
  final Map<String, RelaySubState> relays;

  /// Count of unique events received (after deduplication)
  final int eventCount;

  RelaySubscription({
    required this.id,
    required this.request,
    required this.stream,
    required this.startedAt,
    this.closedAt,
    required this.relays,
    this.eventCount = 0,
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

  RelaySubscription copyWith({
    Request? request,
    bool? stream,
    DateTime? closedAt,
    Map<String, RelaySubState>? relays,
    int? eventCount,
  }) {
    return RelaySubscription(
      id: id,
      request: request ?? this.request,
      stream: stream ?? this.stream,
      startedAt: startedAt,
      closedAt: closedAt ?? this.closedAt,
      relays: relays ?? this.relays,
      eventCount: eventCount ?? this.eventCount,
    );
  }

  /// Update a single relay's state
  RelaySubscription updateRelay(String url, RelaySubState state) {
    return copyWith(relays: {...relays, url: state});
  }
}

/// Pool state - single source of truth
class PoolState {
  final Map<String, RelaySubscription> subscriptions;
  final Map<String, RelaySubscription> closedSubscriptions;
  final List<LogEntry> logs;

  PoolState({
    this.subscriptions = const {},
    this.closedSubscriptions = const {},
    this.logs = const [],
  });

  /// Get subscription by ID (active only)
  RelaySubscription? operator [](String id) => subscriptions[id];

  /// Check if a subscription exists (active only)
  bool hasSubscription(String id) => subscriptions.containsKey(id);

  /// Get closed subscription by ID
  RelaySubscription? closedSubscription(String id) => closedSubscriptions[id];
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
