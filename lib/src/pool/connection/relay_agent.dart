import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket/web_socket.dart';

/// Immutable state for a relay agent
class RelayAgentState {
  final String url;
  final ConnectionPhase phase;
  final DateTime phaseStartedAt;
  final int reconnectAttempts;
  final DateTime? lastActivityAt;
  final String? lastError;
  final Map<String, SubscriptionInfo> activeSubscriptions;
  final DateTime? nextReconnectAt; // When to attempt next reconnection

  const RelayAgentState({
    required this.url,
    required this.phase,
    required this.phaseStartedAt,
    required this.reconnectAttempts,
    this.lastActivityAt,
    this.lastError,
    required this.activeSubscriptions,
    this.nextReconnectAt,
  });

  factory RelayAgentState.initial(String url) {
    return RelayAgentState(
      url: url,
      phase: ConnectionPhase.disconnected,
      phaseStartedAt: DateTime.now(),
      reconnectAttempts: 0,
      activeSubscriptions: const {},
    );
  }

  RelayAgentState copyWith({
    ConnectionPhase? phase,
    DateTime? phaseStartedAt,
    int? reconnectAttempts,
    DateTime? lastActivityAt,
    String? lastError,
    Map<String, SubscriptionInfo>? activeSubscriptions,
    DateTime? nextReconnectAt,
  }) {
    return RelayAgentState(
      url: url,
      phase: phase ?? this.phase,
      phaseStartedAt: phaseStartedAt ?? this.phaseStartedAt,
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      lastError: lastError ?? this.lastError,
      activeSubscriptions: activeSubscriptions ?? this.activeSubscriptions,
      nextReconnectAt: nextReconnectAt ?? this.nextReconnectAt,
    );
  }
}

/// Connection phase enum
enum ConnectionPhase { disconnected, connecting, connected }

/// Subscription info tracked by agent - the ACTUAL filters sent to this relay
class SubscriptionInfo {
  final List<Map<String, dynamic>> filters;
  final DateTime subscribedAt;

  const SubscriptionInfo({required this.filters, required this.subscribedAt});
}

/// Self-contained relay agent that manages a single WebSocket connection
/// Handles reconnection automatically and notifies coordinator via callbacks
class RelayAgent {
  final String url;

  // Callbacks to coordinator
  final void Function(RelayAgentState state) onStateChange;
  final void Function(String relayUrl, String subId, Map<String, dynamic> event)
  onEvent;
  final void Function(String relayUrl, String subId) onEose;
  final void Function(
    String relayUrl,
    String eventId,
    bool accepted,
    String? message,
  )
  onPublishResponse;

  // Configuration
  final Duration connectionTimeout;
  final Duration maxReconnectDelay;

  // Use shorter timeout for connection attempts (faster failure detection)
  // responseTimeout is for query responses, not connection establishment
  // WebSocket connections should establish quickly (5 seconds max)
  Duration get _effectiveConnectionTimeout {
    // Cap connection timeout at 5 seconds for faster reconnection
    // responseTimeout can be longer for query responses, but connections should be fast
    return connectionTimeout.inSeconds > 5
        ? const Duration(seconds: 5)
        : connectionTimeout;
  }

  // Current state
  RelayAgentState _state;

  // WebSocket connection
  WebSocket? _socket;
  StreamSubscription? _socketSubscription;

  // Lifecycle
  bool _disposed = false;

  // Reconnection management
  Timer? _reconnectTimer;
  static const Duration _reconnectCheckInterval = Duration(seconds: 2);

  // Pending publish completers (eventId -> completer)
  final Map<String, Completer<PublishResult>> _pendingPublishes = {};

  RelayAgent({
    required this.url,
    required this.onStateChange,
    required this.onEvent,
    required this.onEose,
    required this.onPublishResponse,
    this.connectionTimeout = const Duration(seconds: 10),
    this.maxReconnectDelay = const Duration(seconds: 30),
  }) : _state = RelayAgentState.initial(url);

  RelayAgentState get state => _state;

  bool get isConnected => _state.phase == ConnectionPhase.connected;

  /// Subscribe to events matching filters
  /// Stores the ACTUAL filters sent to this relay (may be optimized)
  Future<void> subscribe(
    String subId,
    List<Map<String, dynamic>> filters,
  ) async {
    // Add to active subscriptions with the actual filters sent to this relay
    _updateState(
      _state.copyWith(
        activeSubscriptions: {
          ..._state.activeSubscriptions,
          subId: SubscriptionInfo(
            filters: filters,
            subscribedAt: DateTime.now(),
          ),
        },
      ),
    );

    // Connect immediately if not already connected
    if (!isConnected) {
      try {
        await _connect();
      } catch (e) {
        // Connection failed, but will be retried via checkAndReconnect() on next heartbeat
      }
    } else {
      // Already connected, just send the subscription
      _sendSubscription(subId, filters);
    }
  }

  /// Unsubscribe from subscription
  void unsubscribe(String subId) {
    // Send CLOSE if connected
    if (isConnected && _socket != null) {
      try {
        _socket!.sendText(jsonEncode(['CLOSE', subId]));
      } catch (e) {
        // Ignore errors on close
      }
    }

    // Remove from active subscriptions
    final subs = Map<String, SubscriptionInfo>.from(_state.activeSubscriptions);
    subs.remove(subId);
    _updateState(_state.copyWith(activeSubscriptions: subs));

    // Disconnect if no more subscriptions
    if (subs.isEmpty) {
      _closeSocket();
    }
  }

  /// Publish event to relay
  Future<PublishResult> publish(Map<String, dynamic> event) async {
    final eventId = event['id'] as String;

    // Ensure connected (connect if needed)
    if (!isConnected) {
      try {
        await _connect();
      } catch (e) {
        return PublishResult(
          eventId: eventId,
          relayUrl: url,
          accepted: false,
          message: 'Connection failed: $e',
        );
      }
    }

    // Create completer for OK response
    final completer = Completer<PublishResult>();
    _pendingPublishes[eventId] = completer;

    // Set timeout
    Timer(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        completer.complete(
          PublishResult(
            eventId: eventId,
            relayUrl: url,
            accepted: false,
            message: 'Timeout',
          ),
        );
        _pendingPublishes.remove(eventId);
      }
    });

    // Send EVENT
    try {
      _socket!.sendText(jsonEncode(['EVENT', event]));
    } catch (e) {
      completer.complete(
        PublishResult(
          eventId: eventId,
          relayUrl: url,
          accepted: false,
          message: 'Send error: $e',
        ),
      );
      _pendingPublishes.remove(eventId);
    }

    return completer.future;
  }

  /// Check if it's time to reconnect and do so if needed
  /// Called periodically by pool's performHealthCheck
  Future<void> checkAndReconnect({bool force = false}) async {
    if (_disposed || _state.activeSubscriptions.isEmpty) {
      return;
    }

    final now = DateTime.now();

    // If disconnected/reconnecting and it's time to retry
    final readyToReconnect =
        _state.phase == ConnectionPhase.disconnected &&
        (_state.nextReconnectAt == null ||
            now.isAfter(_state.nextReconnectAt!));

    if (readyToReconnect ||
        (force && _state.phase == ConnectionPhase.disconnected)) {
      try {
        await _connect();
      } catch (_) {}
    }
  }

  /// Connect to relay
  Future<void> _connect() async {
    if (_disposed) return;

    _updateState(
      _state.copyWith(
        phase: ConnectionPhase.connecting,
        phaseStartedAt: DateTime.now(),
      ),
    );

    try {
      // Create WebSocket connection
      // Use shorter timeout for faster failure detection during reconnection
      final uri = Uri.parse(url);
      _socket = await WebSocket.connect(
        uri,
      ).timeout(_effectiveConnectionTimeout);

      // Listen to events
      _socketSubscription = _socket!.events.listen(
        _handleSocketEvent,
        onDone: _handleSocketDone,
        onError: _handleSocketError,
        cancelOnError: false,
      );

      // Mark as connected
      _updateState(
        _state.copyWith(
          phase: ConnectionPhase.connected,
          phaseStartedAt: DateTime.now(),
          reconnectAttempts: 0,
          lastError: null,
          lastActivityAt: DateTime.now(),
          nextReconnectAt: null, // Clear on successful connection
        ),
      );

      // Stop reconnection timer since we're connected
      _stopReconnectTimer();

      // Resend all active subscriptions
      for (final entry in _state.activeSubscriptions.entries) {
        _sendSubscription(entry.key, entry.value.filters);
      }
    } catch (e) {
      _scheduleReconnect(now: DateTime.now(), error: e.toString());

      rethrow;
    }
  }

  /// Send subscription to relay
  void _sendSubscription(String subId, List<Map<String, dynamic>> filters) {
    if (_socket == null || !isConnected) return;

    try {
      final message = jsonEncode(['REQ', subId, ...filters]);
      _socket!.sendText(message);
      // Don't update lastActivityAt on send - only update on receive
      // This allows zombie detection to catch dead connections
      // Debug: print('[$url] Sent REQ: $subId');
    } catch (e) {
      // Connection probably died, will be handled by socket error
      // Debug: print('[$url] Failed to send REQ: $e');
    }
  }

  /// Handle WebSocket event
  void _handleSocketEvent(dynamic event) {
    _updateState(_state.copyWith(lastActivityAt: DateTime.now()));

    if (event is TextDataReceived) {
      _handleMessage(event.text);
    }
    // Ignore binary data
  }

  /// Handle WebSocket message
  void _handleMessage(String message) {
    try {
      final data = jsonDecode(message) as List<dynamic>;
      final messageType = data[0] as String;

      switch (messageType) {
        case 'EVENT':
          if (data.length >= 3) {
            final subId = data[1] as String;
            final event = data[2] as Map<String, dynamic>;
            onEvent(url, subId, event);
          }
          break;

        case 'EOSE':
          if (data.length >= 2) {
            final subId = data[1] as String;
            onEose(url, subId);
          }
          break;

        case 'OK':
          if (data.length >= 3) {
            final eventId = data[1] as String;
            final accepted = data[2] as bool;
            final message = data.length > 3 ? data[3] as String? : null;

            onPublishResponse(url, eventId, accepted, message);

            // Complete pending publish
            final completer = _pendingPublishes.remove(eventId);
            if (completer != null && !completer.isCompleted) {
              completer.complete(
                PublishResult(
                  eventId: eventId,
                  relayUrl: url,
                  accepted: accepted,
                  message: message,
                ),
              );
            }
          }
          break;

        case 'CLOSED':
          if (data.length >= 2) {
            final subId = data[1] as String;
            // Relay closed the subscription, resend it
            final sub = _state.activeSubscriptions[subId];
            if (sub != null) {
              _sendSubscription(subId, sub.filters);
            }
          }
          break;

        case 'NOTICE':
          // Ignore for now
          break;
      }
    } catch (e) {
      // Invalid message, ignore
    }
  }

  /// Handle socket done (disconnection)
  void _handleSocketDone() {
    if (_disposed) return;

    final now = DateTime.now();
    _updateState(
      _state.copyWith(
        phase: ConnectionPhase.disconnected,
        phaseStartedAt: now,
        nextReconnectAt: null,
      ),
    );

    _scheduleReconnect(now: now, immediate: true);
  }

  /// Handle socket error
  void _handleSocketError(dynamic error) {
    if (_disposed) return;

    final now = DateTime.now();
    _updateState(
      _state.copyWith(
        phase: ConnectionPhase.disconnected,
        phaseStartedAt: now,
        lastError: error.toString(),
        nextReconnectAt: null,
      ),
    );

    _scheduleReconnect(now: now, immediate: true, error: error.toString());
  }

  /// Close WebSocket connection
  void _closeSocket() {
    _socketSubscription?.cancel();
    _socketSubscription = null;

    if (_socket != null) {
      try {
        _socket!.close();
      } catch (e) {
        // Ignore close errors (socket might already be closed)
      }
      _socket = null;
    }
  }

  /// Start reconnection timer - checks every 2 seconds when disconnected
  void _startReconnectTimer() {
    _stopReconnectTimer();

    if (_disposed || _state.activeSubscriptions.isEmpty) {
      return;
    }

    _reconnectTimer = Timer.periodic(_reconnectCheckInterval, (_) {
      if (_disposed || _state.activeSubscriptions.isEmpty) {
        _stopReconnectTimer();
        return;
      }

      // Only check if we're disconnected/reconnecting
      if (_state.phase == ConnectionPhase.disconnected) {
        checkAndReconnect();
      } else {
        // Connected, stop the timer
        _stopReconnectTimer();
      }
    });
  }

  /// Stop reconnection timer
  void _stopReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _scheduleReconnect({
    required DateTime now,
    String? error,
    bool immediate = false,
  }) {
    if (_disposed || _state.activeSubscriptions.isEmpty) return;

    final attempts = _state.reconnectAttempts + 1;

    final delayMs = immediate
        ? 0
        : min(
            100 * pow(2, attempts - 1).toInt(),
            maxReconnectDelay.inMilliseconds,
          );

    final nextRetry = now.add(Duration(milliseconds: delayMs));

    _updateState(
      _state.copyWith(
        phase: ConnectionPhase.disconnected,
        phaseStartedAt: now,
        reconnectAttempts: attempts,
        lastError: error ?? _state.lastError,
        nextReconnectAt: nextRetry,
      ),
    );

    _startReconnectTimer();
  }

  /// Update state and notify coordinator
  void _updateState(RelayAgentState newState) {
    _state = newState;
    onStateChange(newState);
  }

  /// Dispose agent
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _closeSocket();
    _stopReconnectTimer();

    // Complete pending publishes
    for (final completer in _pendingPublishes.values) {
      if (!completer.isCompleted) {
        completer.complete(
          PublishResult(
            eventId: '',
            relayUrl: url,
            accepted: false,
            message: 'Agent disposed',
          ),
        );
      }
    }
    _pendingPublishes.clear();
  }
}

/// Result of publishing an event
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
