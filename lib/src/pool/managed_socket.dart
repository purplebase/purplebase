import 'dart:async';

import 'relay_socket.dart';

/// Managed relay socket with reconnection state.
///
/// Tracks which subscriptions use this socket, reconnection attempts,
/// and pending ping operations for zombie detection.
class ManagedSocket {
  final String url;
  final RelaySocket socket;
  Timer? reconnectTimer;

  /// Which subscriptions use this socket.
  final Set<String> subscriptionIds = {};

  /// Reconnection attempts for this relay (shared across all subscriptions).
  int reconnectAttempts = 0;

  /// Last error message for this relay.
  String? lastError;

  /// Pending ping completer for zombie detection.
  Completer<void>? pingCompleter;
  static const pingSubId = '__ping__';

  ManagedSocket({required this.url, required this.socket});

  void dispose() {
    reconnectTimer?.cancel();
    pingCompleter?.complete();
    socket.dispose();
  }
}
