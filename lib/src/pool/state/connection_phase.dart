/// Explicit connection phase - replaces boolean flags
/// A relay connection is in exactly one of these states at any time
sealed class ConnectionPhase {
  const ConnectionPhase();
}

/// Relay connection has not been initiated yet
class Idle extends ConnectionPhase {
  const Idle();

  @override
  String toString() => 'Idle';
}

/// Relay connection is being established
class Connecting extends ConnectionPhase {
  final DateTime startedAt;

  const Connecting(this.startedAt);

  @override
  String toString() => 'Connecting(since: $startedAt)';
}

/// Relay is connected and ready to use
class Connected extends ConnectionPhase {
  final DateTime connectedAt;
  final bool isReconnection; // vs initial connection

  const Connected(this.connectedAt, {this.isReconnection = false});

  @override
  String toString() =>
      'Connected(at: $connectedAt, isReconnection: $isReconnection)';
}

/// Relay connection was lost or closed
class Disconnected extends ConnectionPhase {
  final DisconnectionReason reason;
  final DateTime disconnectedAt;

  const Disconnected(this.reason, this.disconnectedAt);

  @override
  String toString() => 'Disconnected(reason: $reason, at: $disconnectedAt)';
}

/// Relay is attempting to reconnect after disconnection
class Reconnecting extends ConnectionPhase {
  final int attemptNumber;
  final DateTime nextAttemptAt;

  const Reconnecting(this.attemptNumber, this.nextAttemptAt);

  @override
  String toString() =>
      'Reconnecting(attempt: $attemptNumber, nextAttempt: $nextAttemptAt)';
}

/// Why did we disconnect? (for debugging)
enum DisconnectionReason {
  /// User called dispose/unsubscribe
  intentional,

  /// WebSocket error
  socketError,

  /// Connection timeout
  timeout,

  /// Detected by health check (stale/stuck)
  healthCheck,

  /// System suspension detected (sleep/airplane mode)
  systemSuspension,

  /// Idle timeout (no active subscriptions)
  idleTimeout,
}


