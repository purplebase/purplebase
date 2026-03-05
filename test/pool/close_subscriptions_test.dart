import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.closeSubscriptions);
  });

  tearDownAll(() => fixture.dispose());
  setUp(() => fixture.clear());

  group('Close subscriptions to relays', () {
    test('closes all subscriptions to a specific relay', () async {
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
      await fixture.stateCapture.waitForSubscription(req2.subscriptionId);

      final cancelled =
          fixture.pool.closeSubscriptionsToRelays({fixture.relayUrl});
      expect(cancelled, isNotEmpty);

      await Future.delayed(Duration(milliseconds: 200));
    });

    test('returns empty set for unknown relay', () {
      final cancelled =
          fixture.pool.closeSubscriptionsToRelays({'ws://unknown:1234'});
      expect(cancelled, isEmpty);
    });

    test('returns empty set for empty relay set', () {
      final cancelled = fixture.pool.closeSubscriptionsToRelays({});
      expect(cancelled, isEmpty);
    });
  });
}
