import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(
      port: TestPorts.buffer,
      captureEvents: true,
    );
  });

  tearDownAll(() => fixture.dispose());
  setUp(() => fixture.clear());

  group('Streaming queries (stream=true)', () {
    test('returns empty immediately', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      final result = await fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );
      expect(result, isEmpty);
      fixture.pool.unsubscribe(req);
    });

    test('delivers events via onEvents callback after publish', () async {
      final note = await PartialNote(
        'streaming test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish(
        [note.toMap()],
        relays: {fixture.relayUrl},
      );

      final req = Request([RequestFilter(ids: {note.id})]);
      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForEose(
        req.subscriptionId,
        fixture.relayUrl,
        timeout: Duration(seconds: 5),
      );

      await Future.delayed(Duration(milliseconds: 200));

      expect(fixture.receivedEvents.any((e) => e['id'] == note.id), isTrue);
      fixture.pool.unsubscribe(req);
    });

    test('persists subscription after EOSE', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForEose(
        req.subscriptionId,
        fixture.relayUrl,
        timeout: Duration(seconds: 10),
      );

      expect(
        fixture.stateCapture.lastState?.subscriptions
            .containsKey(req.subscriptionId),
        isTrue,
      );
      fixture.pool.unsubscribe(req);
    });

    test('stream=true subscription has correct stream flag', () async {
      await fixture.withSubscription(
        stream: true,
        test: (state, sub) {
          expect(sub.stream, isTrue);
        },
      );
    });
  });
}
