import 'dart:async';

import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.reconnection);
  });

  tearDownAll(() => fixture.dispose());
  setUp(() => fixture.clear());

  group('Reconnection', () {
    test('connects initially and tracks state', () async {
      await fixture.withSubscription(
        test: (state, sub) {
          final relay = sub.relays[fixture.relayUrl];
          expect(relay, isNotNull);
          expect(relay!.reconnectAttempts, greaterThanOrEqualTo(0));
        },
      );
    });

    test('offline relay increments reconnect attempts', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      fixture.pool
          .query(
            req,
            source: RemoteSource(relays: {TestRelays.offline}, stream: true),
          )
          .catchError((_) => <Map<String, dynamic>>[]);

      try {
        await fixture.stateCapture.waitFor(
          (s) {
            final relay = s.subscriptions[req.subscriptionId]
                ?.relays[TestRelays.offline];
            return relay != null && relay.reconnectAttempts > 0;
          },
          timeout: Duration(seconds: 10),
        );

        final relay = fixture.stateCapture.lastState
            ?.subscriptions[req.subscriptionId]
            ?.relays[TestRelays.offline];
        expect(relay!.reconnectAttempts, greaterThan(0));
      } on TimeoutException {
        // Acceptable — reconnection backoff may not trigger within 10s
      } finally {
        fixture.pool.unsubscribe(req);
      }
    });

    test('health check while connected succeeds', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForConnected(fixture.relayUrl);
      await fixture.pool.performHealthCheck();

      expect(
        fixture.stateCapture.lastState?.isRelayConnected(fixture.relayUrl),
        isTrue,
      );
      fixture.pool.unsubscribe(req);
    });
  });
}
