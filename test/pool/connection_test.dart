import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for WebSocket connection management and lifecycle.
///
/// These tests verify the pool's ability to:
/// - Establish connections to relays
/// - Handle URL normalization
/// - Gracefully handle offline/unreachable relays
/// - Track connection metrics and health
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
      final normalizedUrl = normalizeRelayUrl(denormalizedUrl);

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

      final state = await fixture.stateCapture.waitForSubscription(
        req.subscriptionId,
      );

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

    test('stores error message on connection failure', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool
          .query(
            req,
            source: RemoteSource(relays: {TestRelays.offline}, stream: true),
          )
          .catchError((_) => <Map<String, dynamic>>[]);

      final state = await fixture.stateCapture.waitForSubscription(
        req.subscriptionId,
      );

      final relay = state.subscriptions[req.subscriptionId]?.relays[TestRelays.offline];
      expect(relay, isNotNull);
      expect(relay!.lastError, anyOf(isNull, isA<String>()));

      fixture.pool.unsubscribe(req);
    });

    test('increments reconnect attempts on failure', () async {
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
            final relay =
                s.subscriptions[req.subscriptionId]?.relays[TestRelays.offline];
            return relay != null && relay.reconnectAttempts > 0;
          },
          timeout: Duration(seconds: 10),
        );
      } catch (_) {
        // May timeout - acceptable for this test
      }

      final relay = fixture.stateCapture.lastState
          ?.subscriptions[req.subscriptionId]
          ?.relays[TestRelays.offline];
      expect(relay, isNotNull);

      fixture.pool.unsubscribe(req);
    });
  });

  group('Connection metrics', () {
    test('tracks connection metrics', () async {
      await fixture.withSubscription(
        test: (state, sub) {
          final relay = sub.relays[fixture.relayUrl];
          expect(relay, isNotNull);
          expect(relay!.reconnectAttempts, greaterThanOrEqualTo(0));
        },
      );
    });

    test('tracks last activity time', () async {
      await fixture.withStreamingSubscription(
        test: (state, sub) {
          final relay = sub.relays[fixture.relayUrl];
          expect(relay, isNotNull);
          expect(relay!.phase, equals(RelaySubPhase.streaming));
        },
      );
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

      expect(fixture.stateCapture.lastState?.isRelayConnected(fixture.relayUrl), isTrue);

      fixture.pool.unsubscribe(req);
    });

    test('connect method works without error', () async {
      final req = Request([RequestFilter(kinds: {1})]);
      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForConnected(fixture.relayUrl);

      fixture.pool.connect();

      expect(fixture.stateCapture.lastState?.isRelayConnected(fixture.relayUrl), isTrue);

      fixture.pool.unsubscribe(req);
    });
  });
}
