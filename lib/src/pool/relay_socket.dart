import 'dart:async';
import 'dart:convert';

import 'package:web_socket/web_socket.dart';

import 'pool_state.dart';

typedef _WebSocketClosed = WebSocketConnectionClosed;

/// Low-level WebSocket wrapper — no reconnection logic, no subscription tracking.
/// Just connect, send, receive, disconnect.
class RelaySocket {
  final String url;

  /// Called when a message is received.
  final void Function(String message) onMessage;

  /// Called when the socket disconnects (cleanly or with error).
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

  void disconnect() {
    _subscription?.cancel();
    _subscription = null;

    final socket = _socket;
    _socket = null;

    if (socket != null) {
      try {
        socket.close();
      } on _WebSocketClosed catch (_) {
        // Already closed
      } catch (_) {
        // Ignore errors during close
      }
    }
  }

  /// Send a text message. Returns true if send succeeded.
  bool send(String message) {
    final socket = _socket;
    if (socket == null) return false;
    try {
      socket.sendText(message);
      return true;
    } on _WebSocketClosed catch (_) {
      _socket = null;
      return false;
    } catch (_) {
      return false;
    }
  }

  bool sendReq(String subId, List<Map<String, dynamic>> filters) {
    return send(jsonEncode(['REQ', subId, ...filters]));
  }

  bool sendClose(String subId) {
    return send(jsonEncode(['CLOSE', subId]));
  }

  bool sendEvent(Map<String, dynamic> event) {
    return send(jsonEncode(['EVENT', event]));
  }

  /// Send a ping request — relay responds with EOSE or CLOSED.
  bool sendPing(String pingSubId) {
    return sendReq(pingSubId, [
      {'limit': 0},
    ]);
  }

  void _handleEvent(dynamic event) {
    _lastActivityAt = DateTime.now();

    if (event is TextDataReceived) {
      onMessage(event.text);
    } else if (event is CloseReceived) {
      _socket = null;
      _subscription?.cancel();
      _subscription = null;
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
