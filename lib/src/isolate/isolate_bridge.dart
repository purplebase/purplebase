import 'dart:async';
import 'dart:isolate';

import 'messages.dart';

/// Typed SendPort/ReceivePort wrapper for isolate communication.
///
/// Provides a clean Future-based API for sending operations to the
/// background isolate and receiving typed responses.
class IsolateBridge {
  final SendPort _sendPort;

  IsolateBridge(this._sendPort);

  /// Send an operation and wait for a response.
  Future<IsolateResponse> send(IsolateOperation operation) async {
    final receivePort = ReceivePort();
    _sendPort.send((operation, receivePort.sendPort));
    return await receivePort.first as IsolateResponse;
  }

  /// Send a heartbeat (fire-and-forget, no response expected).
  void sendHeartbeat(HeartbeatMessage message) {
    _sendPort.send(message);
  }
}
