import 'dart:async';
import 'dart:math';

import 'package:models/models.dart';
import 'package:purplebase/src/pool/connection/relay_connection.dart';
import 'package:purplebase/src/pool/state/connection_phase.dart';
import 'package:purplebase/src/pool/subscription/active_subscription.dart';
import 'package:web_socket_client/web_socket_client.dart' as ws;

/// Manages connection lifecycle and state transitions
/// This is where reconnection logic lives
class ConnectionCoordinator {
  final StorageConfiguration config;

  // Health check configuration (not in StorageConfiguration)
  static const Duration healthCheckInterval = Duration(seconds: 10);

  ConnectionCoordinator({required this.config});

  /// Ensure relay is connected (idempotent)
  /// Returns the connection if successful, throws on failure
  Future<RelayConnection> ensureConnected(
    RelayConnection relay,
    Map<String, ActiveSubscription> subscriptions,
  ) async {
    final url = relay.url;

    // Check if relay is in a healthy connected state
    if (relay.isConnected && relay.socket != null) {
      return relay; // Already connected and healthy
    }

    // If relay is connecting, wait for it to complete
    if (relay.isConnecting) {
      final timeSinceStatusChange = DateTime.now().difference(
        relay.phaseStartedAt,
      );

      if (timeSinceStatusChange < config.responseTimeout) {
        // Wait for connection to complete (or timeout)
        final remainingTimeout = config.responseTimeout - timeSinceStatusChange;
        try {
          await relay.socket?.connection
              .firstWhere(
                (state) => state is ws.Connected || state is ws.Disconnected,
              )
              .timeout(remainingTimeout);

          if (relay.isConnected) {
            return relay; // Connection succeeded
          }
        } catch (e) {
          // Timeout or error while waiting
        }
      }

      // Stuck connecting - force reconnect
      print('[coordinator] Relay $url stuck connecting, forcing reconnect');
      await _cleanupDeadSocket(relay);
    }

    // Clean up any existing dead socket before reconnecting
    if (relay.socket != null && !relay.isConnected) {
      print('[coordinator] Cleaning up dead socket for $url');
      await _cleanupDeadSocket(relay);
    }

    // Establish fresh connection
    await _connect(relay, subscriptions);
    return relay;
  }

  /// Establish connection to relay
  Future<void> _connect(
    RelayConnection relay,
    Map<String, ActiveSubscription> subscriptions,
  ) async {
    final url = relay.url;

    // Validate URL format
    final uri = Uri.parse(url);
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw FormatException('Invalid WebSocket scheme: ${uri.scheme}');
    }
    if (uri.host.isEmpty) {
      throw FormatException('Empty host in URL: $url');
    }

    print('[coordinator] Connecting to $url...');
    relay.transitionTo(Connecting(DateTime.now()));

    try {
      // Create WebSocket WITHOUT auto-reconnection (we handle it ourselves)
      final socket = await Future(
        () => ws.WebSocket(
          uri,
          backoff: const ws.ConstantBackoff(
            Duration.zero,
          ), // Disable auto-reconnect
        ),
      ).timeout(config.responseTimeout);

      relay.socket = socket;
      relay.lastMessageAt = DateTime.now();

      // Set up listeners
      _setupSocketListeners(relay, subscriptions);

      // Wait for connection to be established
      final connectionFuture = socket.connection.firstWhere(
        (state) => state is ws.Connected,
        orElse: () => throw TimeoutException('Connection timeout'),
      );

      await connectionFuture.timeout(config.responseTimeout);

      // Mark as connected
      relay.transitionTo(Connected(DateTime.now(), isReconnection: false));
      relay.reconnectAttempts = 0;

      print('[coordinator] Successfully connected to $url');
    } catch (e) {
      print('[coordinator] Connection failed for $url: $e');
      relay.lastError = e.toString();
      relay.transitionTo(
        Disconnected(DisconnectionReason.socketError, DateTime.now()),
      );
      rethrow;
    }
  }

  /// Set up socket listeners
  void _setupSocketListeners(
    RelayConnection relay,
    Map<String, ActiveSubscription> subscriptions,
  ) {
    final socket = relay.socket;
    if (socket == null) return;

    final url = relay.url;

    // Listen to connection state changes
    relay.connectionSubscription = socket.connection.listen((state) {
      print(
        '[coordinator] Connection state change: $url -> ${state.runtimeType}',
      );

      if (state is ws.Disconnected) {
        handleDisconnection(
          relay,
          DisconnectionReason.socketError,
          subscriptions,
        );
      }
      // We don't want the library to auto-reconnect, but if it does,
      // we'll detect it and handle it appropriately
      else if (state is ws.Reconnected) {
        handleReconnected(relay, subscriptions);
      }
    });

    // Message listener will be set up by WebSocketPool
    // (coordinator only manages connection lifecycle, not message handling)
  }

  /// Handle involuntary disconnection
  void handleDisconnection(
    RelayConnection relay,
    DisconnectionReason reason,
    Map<String, ActiveSubscription> subscriptions,
  ) {
    print('[coordinator] Handling disconnection for ${relay.url}: $reason');

    // Update state to Disconnected
    relay.transitionTo(Disconnected(reason, DateTime.now()));

    // Cancel idle timer
    relay.idleTimer?.cancel();

    // For intentional disconnections, clean up completely
    if (reason == DisconnectionReason.intentional) {
      _cleanupDeadSocket(relay);
      return;
    }

    // For unintentional disconnections, schedule reconnection
    _scheduleReconnection(relay, subscriptions);
  }

  /// Handle reconnection (when WebSocket library auto-reconnects despite our settings)
  void handleReconnected(
    RelayConnection relay,
    Map<String, ActiveSubscription> subscriptions,
  ) {
    print('[coordinator] Handling reconnection for ${relay.url}');

    // Mark as reconnected
    relay.transitionTo(Connected(DateTime.now(), isReconnection: true));
    relay.lastMessageAt = DateTime.now();
    relay.reconnectAttempts = 0;

    // WebSocketPool will handle re-sending subscriptions
  }

  /// Schedule reconnection attempt
  void _scheduleReconnection(
    RelayConnection relay,
    Map<String, ActiveSubscription> subscriptions,
  ) {
    // Check if there are active subscriptions for this relay
    final hasActiveSubscriptions = subscriptions.values.any(
      (sub) => sub.targetRelays.contains(relay.url),
    );

    if (!hasActiveSubscriptions) {
      print(
        '[coordinator] No active subscriptions for ${relay.url}, not reconnecting',
      );
      return;
    }

    relay.reconnectAttempts++;
    final delay = getReconnectionDelay(relay.reconnectAttempts);
    final nextAttempt = DateTime.now().add(delay);

    print(
      '[coordinator] Scheduling reconnection for ${relay.url} '
      '(attempt ${relay.reconnectAttempts}, delay: ${delay.inSeconds}s)',
    );

    relay.transitionTo(Reconnecting(relay.reconnectAttempts, nextAttempt));

    // Note: Actual reconnection will be triggered by health check
    // This just marks the state and when to attempt
  }

  /// Get reconnection delay (exponential backoff, max 30 seconds)
  Duration getReconnectionDelay(int attemptNumber) {
    final milliseconds = min(100 * pow(2, attemptNumber - 1), 30000);
    return Duration(milliseconds: milliseconds.toInt());
  }

  /// Clean up dead socket
  Future<void> _cleanupDeadSocket(RelayConnection relay) async {
    relay.connectionSubscription?.cancel();
    relay.messageSubscription?.cancel();
    relay.idleTimer?.cancel();

    try {
      relay.socket?.close();
    } catch (e) {
      // Ignore close errors on dead sockets
      print('[coordinator] Error closing socket for ${relay.url}: $e');
    }

    relay.socket = null;
  }

  /// Perform health check on connections
  /// Returns list of relays that need attention
  HealthCheckResult performHealthCheck(
    Map<String, RelayConnection> relays,
    Map<String, ActiveSubscription> subscriptions,
    DateTime? lastHealthCheck,
  ) {
    final now = DateTime.now();
    final result = HealthCheckResult();

    // CRITICAL: Detect system suspension (computer sleep, airplane mode, etc.)
    if (lastHealthCheck != null) {
      final actualElapsed = now.difference(lastHealthCheck);
      final expectedElapsed = healthCheckInterval;

      // If actual time is more than 2x expected, we had a time jump (system suspended)
      if (actualElapsed > expectedElapsed * 2) {
        print(
          '[coordinator] SYSTEM SUSPENSION DETECTED! '
          '(expected ${expectedElapsed.inSeconds}s, actual ${actualElapsed.inSeconds}s)',
        );
        result.systemSuspensionDetected = true;

        // Force close ALL connections - they're likely dead
        for (final relay in relays.values) {
          if (relay.socket != null) {
            print('[coordinator] Force-closing ${relay.url} after suspension');
            _cleanupDeadSocket(relay);
            relay.transitionTo(
              Disconnected(DisconnectionReason.systemSuspension, now),
            );
            result.needReconnection.add(relay.url);
          }
        }

        return result;
      }
    }

    // Check each relay
    for (final relay in relays.values) {
      final url = relay.url;

      // Check if there are active subscriptions for this relay
      final hasActiveSubscriptions = subscriptions.values.any(
        (sub) => sub.targetRelays.contains(url),
      );

      // Skip relays with no active work
      if (!hasActiveSubscriptions) continue;

      // CASE 1: Disconnected with active subscriptions
      if (relay.isDisconnected) {
        final timeSinceDisconnect = now.difference(relay.phaseStartedAt);

        if (timeSinceDisconnect > healthCheckInterval) {
          print(
            '[coordinator] Relay $url disconnected for ${timeSinceDisconnect.inSeconds}s, needs reconnection',
          );
          result.needReconnection.add(url);
        }
      }
      // CASE 2: Stuck in reconnecting state
      else if (relay.isReconnecting) {
        final reconnecting = relay.phase as Reconnecting;

        if (now.isAfter(reconnecting.nextAttemptAt)) {
          print('[coordinator] Relay $url ready for reconnection attempt');
          result.needReconnection.add(url);
        }
      }
      // CASE 3: Stuck in "connecting" state
      else if (relay.isConnecting) {
        final timeSinceStatusChange = now.difference(relay.phaseStartedAt);

        if (timeSinceStatusChange > config.responseTimeout * 2) {
          print(
            '[coordinator] Relay $url stuck connecting for ${timeSinceStatusChange.inSeconds}s, forcing reset',
          );
          _cleanupDeadSocket(relay);
          relay.transitionTo(
            Disconnected(DisconnectionReason.healthCheck, now),
          );
          result.needReconnection.add(url);
        }
      }
      // Note: We don't check for "stale" connections based on activity.
      // A relay with no messages is perfectly normal if there are no matching events.
      // The WebSocket library will detect actual dead connections via socket errors.
    }

    return result;
  }

  /// Clean up idle relay (no active subscriptions)
  void cleanupIdleRelay(RelayConnection relay) {
    print('[coordinator] Cleaning up idle relay ${relay.url}');

    // Cancel timers
    relay.idleTimer?.cancel();

    // Mark as intentional disconnection
    relay.transitionTo(
      Disconnected(DisconnectionReason.idleTimeout, DateTime.now()),
    );

    // Close socket
    _cleanupDeadSocket(relay);
  }
}

/// Result of health check
class HealthCheckResult {
  final Set<String> needReconnection = {};
  bool systemSuspensionDetected = false;
}
