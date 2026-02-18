import 'dart:isolate';

import 'package:purplebase/src/isolate/isolate_bridge.dart';
import 'package:purplebase/src/isolate/messages.dart';
import 'package:test/test.dart';

void main() {
  group('IsolateBridge', () {
    test('send and receive response round-trip', () async {
      final receivePort = ReceivePort();
      final bridge = IsolateBridge(receivePort.sendPort);

      // Listen on the port and immediately respond
      receivePort.listen((message) {
        final (IsolateOperation op, SendPort replyPort) = message;
        expect(op, isA<LocalClearOp>());
        replyPort.send(IsolateResponse(success: true));
      });

      final response = await bridge.send(LocalClearOp());
      expect(response.success, isTrue);

      receivePort.close();
    });

    test('sendHeartbeat does not expect a response', () {
      final receivePort = ReceivePort();
      final bridge = IsolateBridge(receivePort.sendPort);

      HeartbeatMessage? received;
      receivePort.listen((message) {
        if (message is HeartbeatMessage) received = message;
      });

      final hb = HeartbeatMessage(DateTime.now());
      bridge.sendHeartbeat(hb);

      // Give it a tick to process
      Future.delayed(Duration(milliseconds: 50), () {
        expect(received, isNotNull);
        receivePort.close();
      });
    });
  });
}
