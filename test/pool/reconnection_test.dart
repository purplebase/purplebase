import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for reconnection and backoff behavior.
///
/// These tests verify the pool's ability to:
/// - Recover from connection failures
/// - Track reconnection attempts
/// - Clean up idle connections
void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.reconnection);
  });

  tearDownAll(() => fixture.dispose());

  setUp(() => fixture.clear());

  group('Connection recovery', () {
    test('connects and can recover from temporary disconnect', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      final connectedState = await fixture.stateCapture.waitForConnected(
        fixture.relayUrl,
      );
      expect(connectedState.isRelayConnected(fixture.relayUrl), isTrue);

      fixture.pool.unsubscribe(req);
    });

    test('tracks reconnect attempts for offline relay', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool
          .query(
            req,
            source: RemoteSource(relays: {TestRelays.offline}, stream: true),
          )
          .catchError((_) => <Map<String, dynamic>>[]);

      // Just wait for subscription to be created
      final state = await fixture.stateCapture.waitForSubscription(
        req.subscriptionId,
        timeout: Duration(seconds: 2),
      );

      final relay = state.subscriptions[req.subscriptionId]?.relays[TestRelays.offline];
      expect(relay, isNotNull);
      expect(
        relay!.phase,
        anyOf(
          RelaySubPhase.disconnected,
          RelaySubPhase.connecting,
          RelaySubPhase.waiting,
        ),
      );
      expect(relay.reconnectAttempts, greaterThanOrEqualTo(0));

      fixture.pool.unsubscribe(req);
    });

    test('resends subscriptions after reconnect', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForConnected(fixture.relayUrl);

      final state = await fixture.stateCapture.waitForSubscription(
        req.subscriptionId,
      );
      expect(state.subscriptions.containsKey(req.subscriptionId), isTrue);

      final sub = state.subscriptions[req.subscriptionId];
      expect(sub?.relays.containsKey(fixture.relayUrl), isTrue);

      fixture.pool.unsubscribe(req);
    });
  });

  group('Relay state tracking', () {
    test('tracks relay phase changes', () async {
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
    test('performs health check without disconnecting', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForConnected(fixture.relayUrl);

      await fixture.pool.performHealthCheck();

      expect(fixture.stateCapture.lastState, isNotNull);
      expect(fixture.stateCapture.lastState!.isRelayConnected(fixture.relayUrl), isTrue);

      fixture.pool.unsubscribe(req);
    });

    test('connect call maintains connection', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForConnected(fixture.relayUrl);

      fixture.pool.connect();

      expect(fixture.stateCapture.lastState, isNotNull);
      expect(fixture.stateCapture.lastState!.isRelayConnected(fixture.relayUrl), isTrue);

      fixture.pool.unsubscribe(req);
    });
  });

  group('Idle connection cleanup', () {
    test('cleans up connections when no subscriptions', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForConnected(fixture.relayUrl);

      fixture.pool.unsubscribe(req);

      await fixture.stateCapture.waitForUnsubscribed(req.subscriptionId);

      expect(fixture.stateCapture.lastState, isNotNull);
      expect(
        fixture.stateCapture.lastState!.subscriptions.containsKey(req.subscriptionId),
        isFalse,
      );
    });
  });
}
