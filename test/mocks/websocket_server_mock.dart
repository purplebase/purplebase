import 'dart:async';
import 'dart:convert';
import 'package:purplebase/purplebase.dart';

class MockWebSocketClient implements WebSocketClient {
  final StreamController<(String relayUrl, String message)>
  _messagesController =
      StreamController<(String relayUrl, String message)>.broadcast();
  final Map<String, bool> _connectionStatus = {};
  final Map<String, List<String>> _sentMessages = {};

  @override
  Future<void> connect(Uri uri) async {
    final url = uri.toString();
    _connectionStatus[url] = true;
    _sentMessages[url] = [];
    return Future.value();
  }

  @override
  void send(String message) {
    // Record sent messages for verification in tests
    for (final url in _connectionStatus.keys) {
      if (_connectionStatus[url]!) {
        _sentMessages[url]!.add(message);
      }
    }
  }

  @override
  void close() {
    _messagesController.close();
    // Set all connections to false
    for (final url in _connectionStatus.keys) {
      _connectionStatus[url] = false;
    }
  }

  @override
  Stream<(String relayUrl, String message)> get messages {
    return _messagesController.stream;
  }

  @override
  bool get isConnected =>
      _connectionStatus.values.any((connected) => connected);

  // Test helper methods
  void sendMessage(String url, String message) {
    if (!_connectionStatus.containsKey(url) || !_connectionStatus[url]!) {
      throw Exception('Cannot receive message when disconnected');
    }
    _messagesController.add((url, message));
  }

  void sendEvent(
    String url,
    String subscriptionId,
    Map<String, dynamic> event,
  ) {
    final message = jsonEncode(['EVENT', subscriptionId, event]);
    sendMessage(url, message);
  }

  void sendEose(String url, String subscriptionId) {
    final message = jsonEncode(['EOSE', subscriptionId]);
    sendMessage(url, message);
  }

  List<String> getSentMessages(String url) {
    return _sentMessages[url] ?? [];
  }
}
