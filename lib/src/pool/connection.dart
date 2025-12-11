import 'dart:async';
import 'dart:convert';

import 'package:web_socket/web_socket.dart';

import 'state.dart';

/// Dumb WebSocket wrapper - no reconnection logic, no subscription tracking.
/// Just connect, send, receive, disconnect.
class RelaySocket {
  final String url;

  /// Called when a message is received
  final void Function(String message) onMessage;

  /// Called when the socket disconnects (cleanly or with error)
  final void Function(String? error) onDisconnect;

  WebSocket? _socket;
  StreamSubscription? _subscription;
  bool _disposed = false;
  DateTime? _lastActivityAt;

  RelaySocket({
    required this.url,
    required this.onMessage,
    required this.onDisconnect,
  });

  bool get isConnected => _socket != null;
  DateTime? get lastActivityAt => _lastActivityAt;

  /// Connect to the relay
  Future<void> connect() async {
    if (_disposed || _socket != null) return;

    final uri = Uri.parse(url);
    _socket = await WebSocket.connect(uri).timeout(PoolConstants.relayTimeout);

    _subscription = _socket!.events.listen(
      _handleEvent,
      onDone: () => _handleDisconnect(null),
      onError: (e) => _handleDisconnect(e.toString()),
      cancelOnError: false,
    );

    _lastActivityAt = DateTime.now();
  }

  /// Disconnect from the relay
  void disconnect() {
    _subscription?.cancel();
    _subscription = null;

    if (_socket != null) {
      try {
        _socket!.close();
      } catch (_) {}
      _socket = null;
    }
  }

  /// Send a text message
  /// Returns true if send succeeded, false if failed
  bool send(String message) {
    if (_socket == null) return false;
    try {
      _socket!.sendText(message);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Send a REQ message. Returns true if sent successfully.
  bool sendReq(String subId, List<Map<String, dynamic>> filters) {
    return send(jsonEncode(['REQ', subId, ...filters]));
  }

  /// Send a CLOSE message. Returns true if sent successfully.
  bool sendClose(String subId) {
    return send(jsonEncode(['CLOSE', subId]));
  }

  /// Send an EVENT message. Returns true if sent successfully.
  bool sendEvent(Map<String, dynamic> event) {
    return send(jsonEncode(['EVENT', event]));
  }

  /// Send a ping request - uses a filter that returns 0 results but is specific
  /// Relay may respond with EOSE or CLOSED - either means connection is alive
  /// Returns true if ping was sent successfully
  bool sendPing(String pingSubId) {
    return sendReq(pingSubId, [
      {'limit': 0},
    ]);
  }

  void _handleEvent(dynamic event) {
    _lastActivityAt = DateTime.now();

    if (event is TextDataReceived) {
      onMessage(event.text);
    }
  }

  void _handleDisconnect(String? error) {
    if (_disposed) return;
    _socket = null;
    _subscription = null;
    onDisconnect(error);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    disconnect();
  }
}
