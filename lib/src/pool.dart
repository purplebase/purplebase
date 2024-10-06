part of purplebase;

class WebSocketPool {
  final Iterable<String> relayUrls;
  final Map<String, WebSocket> clients = {};
  final _controller = StreamController<(String, String)>();

  Stream<(String, String)> get stream => _controller.stream.asBroadcastStream();

  final List<StreamSubscription> subs = [];

  WebSocketPool(this.relayUrls) {
    for (final relayUrl in relayUrls) {
      final backoff = BinaryExponentialBackoff(
          initial: Duration(milliseconds: 100), maximumStep: 10);
      final client = WebSocket(Uri.parse(relayUrl), backoff: backoff);
      clients[relayUrl] = client;
    }
  }

  Future<void> initialize() async {
    for (final MapEntry(key: relayUrl, value: client) in clients.entries) {
      await client.connection.firstWhere((state) => state is Connected);

      subs.add(client.messages.listen((value) {
        _controller.add((relayUrl, value.toString()));
      }));
    }
  }

  void send(String message, {Iterable<String>? relayUrls}) {
    for (final MapEntry(key: relayUrl, value: client) in clients.entries) {
      if (relayUrls != null && !relayUrls.contains(relayUrl)) {
        continue;
      }
      client.send(message);
    }
  }

  Future<void> close() async {
    for (final sub in subs) {
      await sub.cancel();
    }
    for (final client in clients.values) {
      client.close(1000, 'CLOSE_NORMAL');
    }
  }
}
