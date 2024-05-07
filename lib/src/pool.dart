part of purplebase;

class WebSocketPool {
  final Iterable<String> relayUrls;
  final Map<String, WebSocketClient> clients = {};
  final _controller = StreamController<(String, String)>();

  Stream<(String, String)> get stream => _controller.stream;

  final List<StreamSubscription> subs = [];

  WebSocketPool(this.relayUrls) {
    for (final relayUrl in relayUrls) {
      final client = WebSocketClient(
        WebSocketOptions.common(
          connectionRetryInterval: (
            min: const Duration(milliseconds: 500),
            max: const Duration(seconds: 15),
          ),
          timeout: Duration(seconds: 5),
        ),
      );
      client.connect(relayUrl);
      subs.add(client.stream.listen((value) {
        _controller.add((relayUrl, value.toString()));
      }));
      clients[relayUrl] = client;
    }
  }

  void send(String message, {Iterable<String>? relayUrls}) {
    for (final MapEntry(key: relayUrl, value: client) in clients.entries) {
      if (relayUrls != null && !relayUrls.contains(relayUrl)) {
        continue;
      }
      client.add(message);
    }
  }

  Future<void> close() async {
    for (final sub in subs) {
      await sub.cancel();
    }
    for (final client in clients.values) {
      await client.close();
    }
  }
}
