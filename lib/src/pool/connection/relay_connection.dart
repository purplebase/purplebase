import 'dart:async';

import 'package:purplebase/src/pool/state/connection_phase.dart';
import 'package:web_socket_client/web_socket_client.dart' as ws;

/// Wraps a single WebSocket connection to a relay
/// Owned by WebSocketPool, managed by ConnectionCoordinator
class RelayConnection {
  final String url; // Always normalized

  // WebSocket state
  ws.WebSocket? socket;
  StreamSubscription? connectionSubscription;
  StreamSubscription? messageSubscription;

  // Connection state
  ConnectionPhase phase;
  DateTime phaseStartedAt;
  int reconnectAttempts;
  DateTime? lastMessageAt;
  String? lastError;

  // Timers
  Timer? idleTimer;

  RelayConnection({required this.url, ConnectionPhase? initialPhase})
    : phase = initialPhase ?? const Idle(),
      phaseStartedAt = DateTime.now(),
      reconnectAttempts = 0;

  /// Transition to a new phase
  void transitionTo(ConnectionPhase newPhase) {
    phase = newPhase;
    phaseStartedAt = DateTime.now();
  }

  /// Update last message timestamp
  void recordMessage() {
    lastMessageAt = DateTime.now();
  }

  /// Check if in specific phase
  bool get isConnected => phase is Connected;
  bool get isConnecting => phase is Connecting;
  bool get isDisconnected => phase is Disconnected;
  bool get isReconnecting => phase is Reconnecting;
  bool get isIdle => phase is Idle;

  /// Clean up all resources
  void dispose() {
    connectionSubscription?.cancel();
    messageSubscription?.cancel();
    idleTimer?.cancel();
    try {
      socket?.close();
    } catch (_) {
      // Ignore close errors during disposal
    }
    socket = null;
  }
}
