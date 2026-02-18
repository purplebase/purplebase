import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.connection);
  });

  tearDownAll(() => fixture.dispose());
  setUp(() => fixture.clear());

  group('Connection establishment', () {
    test('connects to relay successfully', () async {
      await fixture.withSubscription(
        test: (state, sub) {
          expect(state.isRelayConnected(fixture.relayUrl), isTrue);
        },
      );
    });

    test('normalizes relay URLs', () async {
      final denormalizedUrl = '${fixture.relayUrl}/';
      final normalizedUrl = normalizeRelayUrl(denormalizedUrl)!;
      expect(normalizedUrl, fixture.relayUrl);

      final req = Request([RequestFilter(kinds: {1})]);
      fixture.pool.query(
        req,
        source: RemoteSource(relays: {normalizedUrl}, stream: true),
      );

      final state = await fixture.stateCapture.waitForConnected(normalizedUrl);
      expect(state.isRelayConnected(normalizedUrl), isTrue);
      fixture.pool.unsubscribe(req);
    });

    test('handles empty relay URLs gracefully', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      final result = await fixture.pool.query(
        req,
        source: RemoteSource(relays: <String>{}),
      );
      expect(result, isEmpty);
    });
  });

  group('Offline relay handling', () {
    test('handles connection to offline relay gracefully', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      fixture.pool
          .query(
            req,
            source: RemoteSource(relays: {TestRelays.offline}, stream: true),
          )
          .catchError((_) => <Map<String, dynamic>>[]);

      final state = await fixture.stateCapture
          .waitForSubscription(req.subscriptionId);

      final sub = state.subscriptions[req.subscriptionId];
      expect(sub, isNotNull);

      final relay = sub!.relays[TestRelays.offline];
      expect(relay, isNotNull);
      expect(
        relay!.phase,
        anyOf(
          RelaySubPhase.disconnected,
          RelaySubPhase.connecting,
          RelaySubPhase.waiting,
        ),
      );
      fixture.pool.unsubscribe(req);
    });
  });

  group('Health check', () {
    test('responds to health check while connected', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForConnected(fixture.relayUrl);
      await fixture.pool.performHealthCheck();
      expect(fixture.stateCapture.lastState?.isRelayConnected(fixture.relayUrl),
          isTrue);
      fixture.pool.unsubscribe(req);
    });
  });
}
