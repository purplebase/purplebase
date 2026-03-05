import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.subscription);
  });

  tearDownAll(() => fixture.dispose());
  setUp(() => fixture.clear());

  group('Subscription creation', () {
    test('creates subscription with query()', () async {
      await fixture.withSubscription(
        test: (state, sub) {
          expect(sub.relays.containsKey(fixture.relayUrl), isTrue);
        },
      );
    });

    test('streaming query returns empty immediately', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      final result = await fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );
      expect(result, isEmpty);

      final state = await fixture.stateCapture
          .waitForSubscription(req.subscriptionId);
      expect(state.subscriptions.containsKey(req.subscriptionId), isTrue);
      fixture.pool.unsubscribe(req);
    });

    test('handles multiple subscriptions', () async {
      final req1 = Request([RequestFilter(kinds: {1})]);
      final req2 = Request([RequestFilter(kinds: {2})]);

      fixture.pool.query(
        req1,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );
      fixture.pool.query(
        req2,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req1.subscriptionId);
      final state = await fixture.stateCapture
          .waitForSubscription(req2.subscriptionId);

      expect(state.subscriptions.containsKey(req1.subscriptionId), isTrue);
      expect(state.subscriptions.containsKey(req2.subscriptionId), isTrue);

      fixture.pool.unsubscribe(req1);
      fixture.pool.unsubscribe(req2);
    });

    test('unsubscribing non-existent subscription is safe', () {
      final req = Request([RequestFilter(kinds: {1})]);
      expect(() => fixture.pool.unsubscribe(req), returnsNormally);
    });
  });

  group('Subscription lifecycle', () {
    test('cleans up subscription after unsubscribe', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req.subscriptionId);
      fixture.pool.unsubscribe(req);

      final state = await fixture.stateCapture
          .waitForUnsubscribed(req.subscriptionId);
      expect(state.subscriptions.containsKey(req.subscriptionId), isFalse);
    });

    test('streaming subscription has stream=true', () async {
      await fixture.withSubscription(
        stream: true,
        test: (state, sub) {
          expect(sub.stream, isTrue);
        },
      );
    });
  });
}
