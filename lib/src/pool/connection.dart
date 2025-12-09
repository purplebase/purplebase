import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket/web_socket.dart';

import 'state.dart';

/// Manages a single WebSocket connection with auto-reconnect and ping-based health checks
class Connection {
  final String url;
  final Duration connectionTimeout;
  final Duration maxReconnectDelay;

  // Callbacks
  final void Function(String url, ConnectionStatus status, {String? error, int? attempts}) onStatusChange;
  final void Function(String url, String subId, Map<String, dynamic> event) onEvent;
  final void Function(String url, String subId) onEose;
  final void Function(String url, String eventId, bool accepted, String? message) onPublishResponse;

  // Connection state
  WebSocket? _socket;
  StreamSubscription? _socketSubscription;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  int _reconnectAttempts = 0;
  String? _lastError;
  DateTime? _lastActivityAt;
  bool _disposed = false;
  bool _isConnecting = false;

  // Reconnection
  Timer? _reconnectTimer;
  DateTime? _nextReconnectAt;

  // Connection completer for concurrent connect requests
  Completer<void>? _connectCompleter;

  // Ping-based zombie detection
  Timer? _pingTimer;
  Completer<void>? _pingCompleter;
  static const _pingSubId = '__ping__';
  Duration _pingInterval = const Duration(seconds: 60);
  static const _minPingInterval = Duration(seconds: 60);
  static const _maxPingInterval = Duration(minutes: 5);

  // Active subscriptions (subId -> filters) - for resending on reconnect
  final Map<String, List<Map<String, dynamic>>> _subscriptions = {};

  // Pending publishes (eventId -> completer)
  final Map<String, Completer<PublishResult>> _pendingPublishes = {};

  Connection({
    required this.url,
    required this.onStatusChange,
    required this.onEvent,
    required this.onEose,
    required this.onPublishResponse,
    this.connectionTimeout = const Duration(seconds: 5),
    this.maxReconnectDelay = const Duration(seconds: 30),
  });

  ConnectionStatus get status => _status;
  int get reconnectAttempts => _reconnectAttempts;
  String? get lastError => _lastError;
  DateTime? get lastActivityAt => _lastActivityAt;
  bool get isConnected => _status == ConnectionStatus.connected;
  Set<String> get activeSubscriptionIds => _subscriptions.keys.toSet();

  /// Subscribe to events matching filters
  Future<void> subscribe(String subId, List<Map<String, dynamic>> filters) async {
    _subscriptions[subId] = filters;

    if (!isConnected) {
      try {
        await _connect();
      } catch (_) {
        // Connection failed, will be retried via reconnection logic
        // Don't throw - let the subscription be created, reconnect will resend it
      }
    }

    if (isConnected) {
      _sendSubscription(subId, filters);
    }
  }

  /// Unsubscribe
  void unsubscribe(String subId) {
    _subscriptions.remove(subId);

    if (isConnected && _socket != null) {
      try {
        _socket!.sendText(jsonEncode(['CLOSE', subId]));
      } catch (_) {}
    }

    // Disconnect if no more subscriptions
    if (_subscriptions.isEmpty) {
      _disconnect(intentional: true);
    }
  }

  /// Publish event
  Future<PublishResult> publish(Map<String, dynamic> event) async {
    final eventId = event['id'] as String;

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

    if (!isConnected || _socket == null) {
      return PublishResult(
        eventId: eventId,
        relayUrl: url,
        accepted: false,
        message: 'Not connected',
      );
    }

    final completer = Completer<PublishResult>();
    _pendingPublishes[eventId] = completer;

    // Timeout for publish response
    Timer(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        completer.complete(PublishResult(
          eventId: eventId,
          relayUrl: url,
          accepted: false,
          message: 'Timeout',
        ));
        _pendingPublishes.remove(eventId);
      }
    });

    try {
      _socket!.sendText(jsonEncode(['EVENT', event]));
    } catch (e) {
      completer.complete(PublishResult(
        eventId: eventId,
        relayUrl: url,
        accepted: false,
        message: 'Send error: $e',
      ));
      _pendingPublishes.remove(eventId);
    }

    return completer.future;
  }

  /// Check connection health and reconnect if needed
  Future<void> checkHealth({bool force = false}) async {
    if (_disposed || _subscriptions.isEmpty) return;

    // If disconnected and ready to reconnect
    if (_status == ConnectionStatus.disconnected) {
      final now = DateTime.now();
      if (force || _nextReconnectAt == null || now.isAfter(_nextReconnectAt!)) {
        await _connect();
      }
      return;
    }

    // If connected, send a ping to verify connection is alive
    if (_status == ConnectionStatus.connected && (force || _shouldPing())) {
      await _sendPing();
    }
  }

  bool _shouldPing() {
    if (_lastActivityAt == null) return true;
    return DateTime.now().difference(_lastActivityAt!) > _pingInterval;
  }

  /// Send a ping (limit:0 request) to verify connection
  Future<void> _sendPing() async {
    if (_socket == null || !isConnected) return;
    if (_pingCompleter != null && !_pingCompleter!.isCompleted) return; // Already pinging

    _pingCompleter = Completer<void>();

    try {
      // Send a limit:0 request - should get immediate EOSE
      _socket!.sendText(jsonEncode(['REQ', _pingSubId, {'limit': 0}]));

      // Wait for EOSE with timeout
      await _pingCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          // Ping failed - connection is zombie
          _handleZombieConnection();
        },
      );

      // Ping succeeded - backoff the ping interval
      _pingInterval = Duration(
        milliseconds: min(_pingInterval.inMilliseconds * 2, _maxPingInterval.inMilliseconds),
      );
    } catch (e) {
      _handleZombieConnection();
    } finally {
      // Close the ping subscription
      if (_socket != null && isConnected) {
        try {
          _socket!.sendText(jsonEncode(['CLOSE', _pingSubId]));
        } catch (_) {}
      }
      _pingCompleter = null;
    }
  }

  void _handleZombieConnection() {
    _lastError = 'Connection stale (ping timeout)';
    _disconnect();
    _scheduleReconnect();
  }

  /// Connect to relay
  Future<void> _connect() async {
    if (_disposed) return;

    // If already connecting, wait for that attempt to complete
    if (_isConnecting && _connectCompleter != null) {
      return _connectCompleter!.future;
    }

    _isConnecting = true;
    _connectCompleter = Completer<void>();
    _updateStatus(ConnectionStatus.connecting);

    try {
      final uri = Uri.parse(url);
      _socket = await WebSocket.connect(uri).timeout(connectionTimeout);

      _socketSubscription = _socket!.events.listen(
        _handleSocketEvent,
        onDone: _handleSocketDone,
        onError: _handleSocketError,
        cancelOnError: false,
      );

      _updateStatus(ConnectionStatus.connected);
      _reconnectAttempts = 0;
      _lastError = null;
      _nextReconnectAt = null;
      _lastActivityAt = DateTime.now();
      _pingInterval = _minPingInterval; // Reset ping interval on connect

      _stopReconnectTimer();
      _startPingTimer();

      // Resend all active subscriptions
      for (final entry in _subscriptions.entries) {
        _sendSubscription(entry.key, entry.value);
      }

      _connectCompleter?.complete();
    } catch (e) {
      _lastError = e.toString();
      _updateStatus(ConnectionStatus.disconnected, error: e.toString());
      _scheduleReconnect();
      // Complete normally (not with error) to avoid unhandled async errors
      // when no one is waiting on the completer. Callers check isConnected.
      _connectCompleter?.complete();
      rethrow;
    } finally {
      _isConnecting = false;
      _connectCompleter = null;
    }
  }

  void _disconnect({bool intentional = false}) {
    _stopPingTimer();
    _socketSubscription?.cancel();
    _socketSubscription = null;

    if (_socket != null) {
      try {
        _socket!.close();
      } catch (_) {}
      _socket = null;
    }

    if (intentional) {
      _reconnectAttempts = 0;
      _stopReconnectTimer();
    }

    _updateStatus(ConnectionStatus.disconnected);
  }

  void _sendSubscription(String subId, List<Map<String, dynamic>> filters) {
    if (_socket == null || !isConnected) return;
    try {
      _socket!.sendText(jsonEncode(['REQ', subId, ...filters]));
    } catch (_) {}
  }

  void _handleSocketEvent(dynamic event) {
    _lastActivityAt = DateTime.now();

    if (event is TextDataReceived) {
      _handleMessage(event.text);
    }
  }

  void _handleMessage(String message) {
    try {
      final data = jsonDecode(message) as List<dynamic>;
      final messageType = data[0] as String;

      switch (messageType) {
        case 'EVENT':
          if (data.length >= 3) {
            final subId = data[1] as String;
            if (subId == _pingSubId) return; // Ignore ping events
            final event = data[2] as Map<String, dynamic>;
            onEvent(url, subId, event);
          }

        case 'EOSE':
          if (data.length >= 2) {
            final subId = data[1] as String;
            if (subId == _pingSubId) {
              // Ping response received
              _pingCompleter?.complete();
              return;
            }
            onEose(url, subId);
          }

        case 'OK':
          if (data.length >= 3) {
            final eventId = data[1] as String;
            final accepted = data[2] as bool;
            final msg = data.length > 3 ? data[3] as String? : null;

            onPublishResponse(url, eventId, accepted, msg);

            final completer = _pendingPublishes.remove(eventId);
            if (completer != null && !completer.isCompleted) {
              completer.complete(PublishResult(
                eventId: eventId,
                relayUrl: url,
                accepted: accepted,
                message: msg,
              ));
            }
          }

        case 'CLOSED':
          if (data.length >= 2) {
            final subId = data[1] as String;
            if (subId == _pingSubId) return;
            // Relay closed the subscription - resend if still active
            final filters = _subscriptions[subId];
            if (filters != null) {
              _sendSubscription(subId, filters);
            }
          }

        case 'NOTICE':
          // Could emit if needed
          break;
      }
    } catch (_) {}
  }

  void _handleSocketDone() {
    if (_disposed) return;
    _socket = null;
    _socketSubscription = null;
    _updateStatus(ConnectionStatus.disconnected);
    _scheduleReconnect();
  }

  void _handleSocketError(dynamic error) {
    if (_disposed) return;
    _lastError = error.toString();
    _socket = null;
    _socketSubscription = null;
    _updateStatus(ConnectionStatus.disconnected, error: error.toString());
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _subscriptions.isEmpty) return;

    _reconnectAttempts++;
    final delayMs = min(
      100 * pow(2, _reconnectAttempts - 1).toInt(),
      maxReconnectDelay.inMilliseconds,
    );
    _nextReconnectAt = DateTime.now().add(Duration(milliseconds: delayMs));

    _stopReconnectTimer();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed && _subscriptions.isNotEmpty) {
        _connect().catchError((_) {});
      }
    });
  }

  void _stopReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _startPingTimer() {
    _stopPingTimer();
    // Check for pings periodically
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (isConnected && _shouldPing()) {
        _sendPing();
      }
    });
  }

  void _stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _updateStatus(ConnectionStatus newStatus, {String? error}) {
    final oldStatus = _status;
    _status = newStatus;

    if (oldStatus != newStatus || error != null) {
      onStatusChange(
        url,
        newStatus,
        error: error ?? _lastError,
        attempts: _reconnectAttempts,
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _disconnect(intentional: true);
    _stopReconnectTimer();
    _stopPingTimer();

    // Complete pending publishes
    for (final completer in _pendingPublishes.values) {
      if (!completer.isCompleted) {
        completer.complete(PublishResult(
          eventId: '',
          relayUrl: url,
          accepted: false,
          message: 'Connection disposed',
        ));
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

