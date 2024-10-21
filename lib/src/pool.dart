part of purplebase;

class WebSocketPool {
  final Iterable<String> relayUrls;
  final Map<String, WebSocket> clients = {};
  final _controller = StreamController<(String, String)>();

  Stream<(String, String)> get stream => _controller.stream.asBroadcastStream();

  List<String> get connectedRelayUrls => clients.entries
      .where((e) => e.value.connection.state == Connected())
      .map((e) => e.key)
      .toList();

  final List<StreamSubscription> subs = [];

  WebSocketPool(this.relayUrls) {
    for (final relayUrl in relayUrls) {
      // TODO: Check durations
      final backoff = BinaryExponentialBackoff(
          initial: Duration(seconds: 2), maximumStep: 10);
      final client = WebSocket(Uri.parse(relayUrl), backoff: backoff);

      subs.add(client.connection.listen((state) {
        print('$relayUrl state changed to ${state.runtimeType}');
        switch (state) {
          case Connected() || Reconnected():
            while (_queue[relayUrl]?.isNotEmpty ?? false) {
              print(
                  'emptying queue of len ${_queue.length} ${state.runtimeType}');
              send(_queue[relayUrl]!.removeAt(0));
            }
          // TODO: Reconnection logic, re-request events since connection dropped
        }
      }));

      subs.add(client.messages.listen((value) {
        _controller.add((relayUrl, value.toString()));
      }));

      clients[relayUrl] = client;
    }
  }

  final _queue = <String, List<String>>{};

  void send(String message) {
    for (final MapEntry(key: relayUrl, value: client) in clients.entries) {
      _queue[relayUrl] ??= [];
      switch (client.connection.state) {
        case Connected() || Reconnected():
          print(
              '[${DateTime.now().toIso8601String()}] Sending req to $relayUrl');
          client.send(message);
          break;
        default:
          print(
              '[${DateTime.now().toIso8601String()}] QUEUING req to $relayUrl');
          _queue[relayUrl]!.add(message);
      }
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
