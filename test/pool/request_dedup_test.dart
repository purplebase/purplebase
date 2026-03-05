import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.requestDedup);
  });

  tearDownAll(() => fixture.dispose());
  setUp(() => fixture.clear());

  group('Pool-level request deduplication', () {
    test('duplicate streaming query returns empty without creating new sub',
        () async {
      final filters = [RequestFilter(kinds: {1})];
      final req1 = Request(filters);
      final req2 = Request(filters);

      fixture.pool.query(
        req1,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req1.subscriptionId);

      // Second identical query should be deduped
      final result = await fixture.pool.query(
        req2,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      expect(result, isEmpty);
      fixture.pool.unsubscribe(req1);
      fixture.pool.unsubscribe(req2);
    });

    test('different filters are NOT deduped', () async {
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

    test('blocking query is not deduped against streaming', () async {
      final filters = [RequestFilter(kinds: {1})];
      final streamReq = Request(filters);

      fixture.pool.query(
        streamReq,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(streamReq.subscriptionId);

      // Blocking query with same filters should still execute
      final blockReq = Request(filters);
      final result = await fixture.pool.query(
        blockReq,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: false),
      );

      expect(result, isA<List<Map<String, dynamic>>>());
      fixture.pool.unsubscribe(streamReq);
    });
  });
}
