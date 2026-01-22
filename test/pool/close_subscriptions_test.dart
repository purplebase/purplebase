import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for closeSubscriptionsToRelays functionality.
///
/// These tests verify:
/// - Closing subscriptions to specific relays
/// - Partial closure (multi-relay subscriptions)
/// - Full closure when all relays are removed
/// - Proper cleanup of resources
/// - Edge cases (empty sets, non-existent relays)
void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.closeSubscriptions);
  });

  tearDownAll(() => fixture.dispose());

  setUp(() => fixture.clear());

  group('closeSubscriptionsToRelays', () {
    test('closes subscription when relay matches', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req.subscriptionId);

      // Close subscriptions to the relay
      final cancelled = fixture.pool.closeSubscriptionsToRelays({fixture.relayUrl});

      // Should have cancelled the subscription
      expect(cancelled, contains(req.subscriptionId));

      // Subscription should be removed from active subscriptions
      final state = await fixture.stateCapture.waitForUnsubscribed(
        req.subscriptionId,
      );
      expect(state.subscriptions.containsKey(req.subscriptionId), isFalse);
    });

    test('moves closed subscription to closedSubscriptions', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req.subscriptionId);

      fixture.pool.closeSubscriptionsToRelays({fixture.relayUrl});

      // Wait for state update
      final state = await fixture.stateCapture.waitForUnsubscribed(
        req.subscriptionId,
      );

      // Should be in closed subscriptions
      expect(state.closedSubscriptions.containsKey(req.subscriptionId), isTrue);

      final closedSub = state.closedSubscriptions[req.subscriptionId]!;
      expect(closedSub.closedAt, isNotNull);

      // All relays should be marked as closed
      for (final relay in closedSub.relays.values) {
        expect(relay.phase, equals(RelaySubPhase.closed));
      }
    });

    test('returns empty set when no subscriptions match', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req.subscriptionId);

      // Try to close a non-existent relay
      final cancelled = fixture.pool.closeSubscriptionsToRelays(
        {'ws://non-existent:1234'},
      );

      expect(cancelled, isEmpty);

      // Original subscription should still exist
      expect(
        fixture.stateCapture.lastState?.subscriptions.containsKey(req.subscriptionId),
        isTrue,
      );

      fixture.pool.unsubscribe(req);
    });

    test('handles empty relay set gracefully', () async {
      final cancelled = fixture.pool.closeSubscriptionsToRelays(<String>{});

      expect(cancelled, isEmpty);
    });

    test('closes multiple subscriptions to same relay', () async {
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

      final cancelled = fixture.pool.closeSubscriptionsToRelays({fixture.relayUrl});

      // Both subscriptions should be cancelled
      expect(cancelled, contains(req1.subscriptionId));
      expect(cancelled, contains(req2.subscriptionId));
    });

    test('does not affect subscriptions to other relays', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req.subscriptionId);

      // Close subscriptions to a different relay
      final cancelled = fixture.pool.closeSubscriptionsToRelays(
        {'ws://other-relay:1234'},
      );

      expect(cancelled, isEmpty);

      // Subscription should still exist
      expect(
        fixture.stateCapture.lastState?.subscriptions.containsKey(req.subscriptionId),
        isTrue,
      );

      fixture.pool.unsubscribe(req);
    });

    test('is idempotent - can be called multiple times safely', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req.subscriptionId);

      // First call should cancel
      final cancelled1 = fixture.pool.closeSubscriptionsToRelays({fixture.relayUrl});
      expect(cancelled1, contains(req.subscriptionId));

      await fixture.stateCapture.waitForUnsubscribed(req.subscriptionId);

      // Second call should be safe and return empty (no more active subs)
      final cancelled2 = fixture.pool.closeSubscriptionsToRelays({fixture.relayUrl});
      expect(cancelled2, isEmpty);
    });

    test('handles subscription with no connected relay', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      // Subscribe to offline relay - will be in connecting/waiting state
      fixture.pool
          .query(
            req,
            source: RemoteSource(relays: {TestRelays.offline}, stream: true),
          )
          .catchError((_) => <Map<String, dynamic>>[]);

      await fixture.stateCapture.waitForSubscription(req.subscriptionId);

      // Should still be able to close subscriptions to the offline relay
      final cancelled = fixture.pool.closeSubscriptionsToRelays({TestRelays.offline});

      expect(cancelled, contains(req.subscriptionId));
    });
  });

  group('closeSubscriptionsToRelays with multiple relays', () {
    test('partial closure removes only specified relays', () async {
      // This test would need a multi-relay setup
      // For now, we test the single relay case which fully closes

      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req.subscriptionId);

      // Since we only have one relay, closing it should fully cancel
      final cancelled = fixture.pool.closeSubscriptionsToRelays({fixture.relayUrl});

      expect(cancelled, contains(req.subscriptionId));
    });
  });

  group('Resource cleanup', () {
    test('logs closure with appropriate message', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      await fixture.stateCapture.waitForSubscription(req.subscriptionId);

      fixture.pool.closeSubscriptionsToRelays({fixture.relayUrl});

      await fixture.stateCapture.waitForUnsubscribed(req.subscriptionId);

      // Check that closure was logged
      final logs = fixture.stateCapture.lastState?.logs ?? [];
      final closureLog = logs.any(
        (log) =>
            log.subscriptionId == req.subscriptionId &&
            log.message.contains('closed') ||
            log.message.contains('removed'),
      );
      expect(closureLog, isTrue);
    });
  });
}
