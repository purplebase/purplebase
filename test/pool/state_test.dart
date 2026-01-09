import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for pool state management and tracking.
///
/// These tests verify the PoolState structure and its ability to:
/// - Track subscription and relay states
/// - Provide accurate connection status
/// - Include useful logging information
void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.state);
  });

  tearDownAll(() => fixture.dispose());

  setUp(() => fixture.clear());

  group('State structure', () {
    test('emits state with correct structure', () async {
      await fixture.withSubscription(
        test: (state, sub) {
          expect(state.subscriptions, isA<Map<String, RelaySubscription>>());
          expect(state.logs, isA<List<LogEntry>>());
        },
      );
    });

    test('tracks relay connection state within subscription', () async {
      await fixture.withSubscription(
        test: (state, sub) {
          final relay = sub.relays[fixture.relayUrl];

          expect(relay, isNotNull);
          expect(
            relay!.phase,
            anyOf(
              RelaySubPhase.connecting,
              RelaySubPhase.loading,
              RelaySubPhase.streaming,
            ),
          );
        },
      );
    });

    test('tracks subscription state', () async {
      await fixture.withSubscription(
        test: (state, sub) {
          expect(sub.request, isNotNull);
          expect(sub.relays, contains(fixture.relayUrl));
          expect(sub.startedAt, isNotNull);
        },
      );
    });
  });

  group('Convenience getters', () {
    test('connectedCount returns correct value', () async {
      await fixture.withStreamingSubscription(
        test: (state, sub) {
          expect(state.connectedCount, equals(1));
        },
      );
    });

    test('isRelayConnected returns correct value', () async {
      await fixture.withStreamingSubscription(
        test: (state, sub) {
          expect(state.isRelayConnected(fixture.relayUrl), isTrue);
        },
      );
    });
  });

  group('Relay phases', () {
    test('tracks EOSE via streaming phase', () async {
      await fixture.withStreamingSubscription(
        test: (state, sub) {
          final relay = sub.relays[fixture.relayUrl];
          expect(relay, isNotNull);
          expect(relay!.phase, equals(RelaySubPhase.streaming));
        },
      );
    });

    test('handles offline relay state', () async {
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
      // Offline relay can be in any non-streaming state
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

  group('Subscription status', () {
    test('statusText contains relay info', () async {
      await fixture.withStreamingSubscription(
        test: (state, sub) {
          expect(sub.statusText, isNotNull);
          expect(sub.statusText, contains('relay'));
        },
      );
    });
  });

  group('Logging', () {
    test('includes logs in state', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForEose(req.subscriptionId, fixture.relayUrl);

      fixture.pool.unsubscribe(req);

      final state = await fixture.stateCapture.waitForUnsubscribed(
        req.subscriptionId,
      );

      expect(state.logs, isA<List<LogEntry>>());
    });
  });
}
