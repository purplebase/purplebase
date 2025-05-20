import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:web_socket_client/web_socket_client.dart';

class WebSocketClient {
  final Map<Uri, WebSocket> _sockets = {};
  final StreamController<(String relayUrl, String message)>
  _messagesController =
      StreamController<(String relayUrl, String message)>.broadcast();
  final _subs = <StreamSubscription>{};
  final _queue = <Uri, List<String>>{};

  Future<bool> connect(Uri uri) async {
    // Return true if already connected
    if (_sockets.containsKey(uri)) {
      return true;
    }

    // Create a completer to track connection success
    final completer = Completer<bool>();

    // Set up a timeout of 10 seconds
    final timeout = Timer(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    // Create the WebSocket with backoff strategy
    final socket = WebSocket(
      uri,
      backoff: BinaryExponentialBackoff(
        initial: Duration(milliseconds: 100),
        maximumStep: 8,
      ),
    );
    _sockets[uri] = socket;

    // Setup message listener
    _subs.add(
      socket.messages.listen((message) {
        // print('received $message');
        _messagesController.add((uri.toString(), message));
      }),
    );

    _subs.add(
      socket.connection.listen((state) {
        switch (state) {
          case Connected() || Reconnected():
            while (_queue[uri]?.isNotEmpty ?? false) {
              _sockets[uri]!.send(_queue[uri]!.removeAt(0));
            }

            if (!completer.isCompleted) {
              // print('connected to $uri!');
              completer.complete(true);
              timeout.cancel();
            }
          case _: // no-op
        }
      }),
    );

    // Wait for either connection success or timeout
    return await completer.future;
  }

  void send(String message, {Set<String>? relayUrls}) {
    // Send to all connected sockets
    for (final MapEntry(key: uri, value: client) in _sockets.entries) {
      if (relayUrls != null && !relayUrls.contains(uri.toString())) {
        // If relayUrls specified but this relay not there, skip
        continue;
      }
      _queue[uri] ??= [];
      switch (client.connection.state) {
        case Connected() || Reconnected():
          // print(
          //   '[${DateTime.now().toIso8601String()}] Sending req to $uri: $message...',
          // );
          client.send(message);
        case _:
          // print(
          //   '[${DateTime.now().toIso8601String()}] QUEUING req to $uri: $message...',
          // );
          if (!_queue[uri]!.contains(message)) {
            _queue[uri]!.add(message);
          }
      }
    }
  }

  void close() {
    for (final socket in _sockets.values) {
      socket.close(1000, 'CLOSE_NORMAL');
    }
    _sockets.clear();
  }

  Stream<(String relayUrl, String message)> get messages =>
      _messagesController.stream;
}

final webSocketClientProvider = Provider<WebSocketClient>((ref) {
  return WebSocketClient();
});
