/// Pool state model — single source of truth for all pool state.
library;

import 'package:models/models.dart';

/// Timing and limit constants for the pool.
abstract class PoolConstants {
  /// Timeout for WebSocket connection and ping operations.
  static const relayTimeout = Duration(seconds: 5);

  /// Only ping if no activity for this duration.
  /// Set to 55s (under 60s) to avoid silent closure by NAT gateways.
  static const pingIdleThreshold = Duration(seconds: 55);

  /// Interval between health checks from main isolate.
  static const healthCheckInterval = Duration(minutes: 1);

  /// Maximum log entries to keep.
  static const maxLogEntries = 200;

  /// Maximum closed subscriptions to keep in history.
  static const maxClosedSubscriptions = 200;

  /// Backoff schedule: delay = 2^n seconds, repeated 2^n times.
  /// Total: 31 attempts, then fail.
  static const _maxBackoffLevel = 4;

  /// Total attempts before failure.
  static const maxRetries = 31;

  /// Get the backoff delay for a given attempt number (1-based).
  static Duration? getBackoffDelay(int attempt) {
    if (attempt < 1 || attempt > maxRetries) return null;

    var cumulativeAttempts = 0;
    for (var n = 0; n <= _maxBackoffLevel; n++) {
      final attemptsAtLevel = 1 << n;
      cumulativeAttempts += attemptsAtLevel;
      if (attempt <= cumulativeAttempts) {
        final delaySeconds = 1 << n;
        return Duration(seconds: delaySeconds);
      }
    }
    return null;
  }
}

/// Pool-level EOSE / timeout configuration.
class PoolConfiguration {
  /// Grace window after first EOSE. Default 200ms.
  final Duration eoseGraceWindow;

  /// Absolute EOSE timeout when querying multiple relays.
  final Duration eoseTimeout;

  /// Absolute EOSE timeout when querying a single relay.
  final Duration eoseTimeoutSingleRelay;

  /// Per-relay connection timeout.
  final Duration connectionTimeout;

  const PoolConfiguration({
    this.eoseGraceWindow = const Duration(milliseconds: 200),
    this.eoseTimeout = const Duration(seconds: 15),
    this.eoseTimeoutSingleRelay = const Duration(seconds: 30),
    this.connectionTimeout = const Duration(seconds: 10),
  });
}

/// Unified phase for a relay-subscription pair.
enum RelaySubPhase {
  disconnected,
  connecting,
  loading,
  streaming,
  waiting,
  failed,
  closed,
}

/// Log entry severity level.
enum LogLevel { info, warning, error }

/// A log entry for debugging and monitoring.
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

/// State of a relay within a subscription.
class RelaySubState {
  final RelaySubPhase phase;
  final DateTime? lastEventAt;
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

/// A subscription with per-relay state.
class RelaySubscription {
  final String id;
  final Request request;
  final bool stream;
  final DateTime startedAt;
  final DateTime? closedAt;
  final Map<String, RelaySubState> relays;
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

  int get activeRelayCount =>
      relays.values.where((r) => r.phase == RelaySubPhase.streaming).length;

  int get totalRelayCount => relays.length;

  bool get allFailed =>
      totalRelayCount > 0 &&
      relays.values.every((r) => r.phase == RelaySubPhase.failed);

  bool get hasActiveRelay => activeRelayCount > 0;

  bool get allEoseReceived => relays.values.every(
    (r) =>
        r.phase == RelaySubPhase.streaming || r.phase == RelaySubPhase.failed,
  );

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

  RelaySubscription updateRelay(String url, RelaySubState state) {
    return copyWith(relays: {...relays, url: state});
  }
}

/// Pool state — single source of truth.
class PoolState {
  final Map<String, RelaySubscription> subscriptions;
  final Map<String, RelaySubscription> closedSubscriptions;
  final List<LogEntry> logs;

  PoolState({
    this.subscriptions = const {},
    this.closedSubscriptions = const {},
    this.logs = const [],
  });

  RelaySubscription? operator [](String id) => subscriptions[id];
  bool hasSubscription(String id) => subscriptions.containsKey(id);
  RelaySubscription? closedSubscription(String id) => closedSubscriptions[id];
}

/// Result of publishing an event to a relay.
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
