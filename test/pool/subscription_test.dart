import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for subscription management
void main() {
  late Process? relayProcess;
  late RelayPool pool;
  late PoolStateCapture stateCapture;
  late ProviderContainer container;
  late Bip340PrivateKeySigner signer;

  const relayPort = 3336;
  const relayUrl = 'ws://localhost:$relayPort';

  setUpAll(() async {
    final tempContainer = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );
    final tempConfig = StorageConfiguration(
      skipVerification: true,
      defaultRelays: {
        'temp': {'wss://temp.com'},
      },
      defaultQuerySource: const LocalAndRemoteSource(
        relays: 'temp',
        stream: false,
      ),
    );
    await tempContainer.read(initializationProvider(tempConfig).future);

    // Start test relay once for all tests
    relayProcess = await startTestRelay(relayPort);
  });

  setUp(() async {
    container = ProviderContainer();
    stateCapture = PoolStateCapture();

    final config = testConfig(relayUrl);

    pool = RelayPool(
      config: config,
      onStateChange: stateCapture.onState,
      onEvents: ({required req, required events, required relaysForIds}) {},
    );

    signer = Bip340PrivateKeySigner(
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      container.read(refProvider),
    );
    await signer.signIn();

    // Clear relay state between tests
    await relayProcess!.clear();
  });

  tearDown(() {
    pool.dispose();
  });

  tearDownAll(() async {
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  test('should create subscription with query()', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for subscription to be created
    final state = await stateCapture.waitForSubscription(req.subscriptionId);
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull, reason: 'Subscription should exist');
    expect(
      subscription!.id,
      equals(req.subscriptionId),
      reason: 'Subscription ID should match',
    );
    expect(
      subscription.relays.containsKey(relayUrl),
      isTrue,
      reason: 'Should have target relay',
    );

    pool.unsubscribe(req);
  });

  test('should handle query with background=true', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    final result = await pool.query(
      req,
      source: RemoteSource(relays: {relayUrl}, background: true),
    );

    // Background queries return empty immediately
    expect(result, isEmpty, reason: 'Background query should return empty');

    // Wait for subscription to be created
    final state = await stateCapture.waitForSubscription(req.subscriptionId);
    expect(
      state.subscriptions.containsKey(req.subscriptionId),
      isTrue,
      reason: 'Background subscription should be created',
    );

    pool.unsubscribe(req);
  });

  test('should handle unsubscribe with non-existent subscription', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Should not throw when unsubscribing non-existent subscription
    expect(
      () => pool.unsubscribe(req),
      returnsNormally,
      reason: 'Should handle non-existent unsubscribe gracefully',
    );
  });

  test('should handle streaming subscription', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Start streaming
    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for subscription
    final state = await stateCapture.waitForSubscription(req.subscriptionId);
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(subscription!.stream, isTrue, reason: 'Should be streaming');

    pool.unsubscribe(req);
  });

  test('should track subscription state correctly', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for EOSE to ensure subscription is fully established
    final state = await stateCapture.waitForEose(req.subscriptionId, relayUrl);
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(subscription!.startedAt, isNotNull);
    expect(subscription.relays, isNotEmpty);
    expect(subscription.activeRelayCount, greaterThanOrEqualTo(1));

    pool.unsubscribe(req);
  });

  test('should handle query with empty relay URLs', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    final result = await pool.query(
      req,
      source: RemoteSource(relays: <String>{}),
    );
    expect(result, isEmpty, reason: 'Should return empty for empty relay URLs');
  });

  test('should handle multiple subscriptions', () async {
    final req1 = Request([
      RequestFilter(kinds: {1}),
    ]);
    final req2 = Request([
      RequestFilter(kinds: {2}),
    ]);

    pool.query(req1, source: RemoteSource(relays: {relayUrl}, stream: true));
    pool.query(req2, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for both subscriptions
    await stateCapture.waitForSubscription(req1.subscriptionId);
    final state = await stateCapture.waitForSubscription(req2.subscriptionId);

    expect(
      state.subscriptions.containsKey(req1.subscriptionId),
      isTrue,
      reason: 'First subscription should exist',
    );
    expect(
      state.subscriptions.containsKey(req2.subscriptionId),
      isTrue,
      reason: 'Second subscription should exist',
    );

    pool.unsubscribe(req1);
    pool.unsubscribe(req2);
  });

  test('should clean up subscription after unsubscribe', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for subscription to be created
    await stateCapture.waitForSubscription(req.subscriptionId);

    pool.unsubscribe(req);

    // Wait for subscription to be removed
    final state = await stateCapture.waitForUnsubscribed(req.subscriptionId);

    expect(
      state.subscriptions.containsKey(req.subscriptionId),
      isFalse,
      reason: 'Subscription should be removed after unsubscribe',
    );
  });

  group('EOSE Handling', () {
    test('should track EOSE received from relay (streaming phase)', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for EOSE
      final state = await stateCapture.waitForEose(
        req.subscriptionId,
        relayUrl,
      );
      final subscription = state.subscriptions[req.subscriptionId];
      final relay = subscription?.relays[relayUrl];

      expect(subscription, isNotNull);
      expect(relay, isNotNull);
      expect(relay!.phase, equals(RelaySubPhase.streaming));

      pool.unsubscribe(req);
    });

    test('should report status after EOSE', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for EOSE
      final state = await stateCapture.waitForEose(
        req.subscriptionId,
        relayUrl,
      );
      final subscription = state.subscriptions[req.subscriptionId];

      expect(subscription, isNotNull);
      // statusText should show relay count
      expect(subscription!.statusText, contains('relay'));

      pool.unsubscribe(req);
    });
  });

  group('Subscription Lifecycle', () {
    test('should complete foreground query after EOSE', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      // Foreground query should complete after EOSE
      // Note: stream: false is required for foreground (non-streaming) queries
      final result = await pool.query(
        req,
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );

      // Should return a list (may be empty)
      expect(result, isA<List<Map<String, dynamic>>>());

      // Wait for the unsubscribe state to be emitted
      final state = await stateCapture.waitForUnsubscribed(req.subscriptionId);
      expect(
        state.subscriptions.containsKey(req.subscriptionId),
        isFalse,
        reason: 'Foreground subscription should be cleaned up after completion',
      );
    });

    test('should keep streaming subscription after EOSE', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      // Streaming query
      pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for EOSE
      await stateCapture.waitForEose(req.subscriptionId, relayUrl);

      // Subscription should still exist
      final state = stateCapture.lastState;
      expect(
        state?.subscriptions.containsKey(req.subscriptionId),
        isTrue,
        reason: 'Streaming subscription should persist after EOSE',
      );

      pool.unsubscribe(req);
    });

    test('should handle cancel during active subscription', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      // Start streaming
      pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for subscription
      await stateCapture.waitForSubscription(req.subscriptionId);

      // Cancel immediately
      pool.unsubscribe(req);

      // Should clean up
      final state = await stateCapture.waitForUnsubscribed(req.subscriptionId);
      expect(state.subscriptions.containsKey(req.subscriptionId), isFalse);
    });

    test('should properly dispose all subscriptions on pool dispose', () async {
      final req1 = Request([
        RequestFilter(kinds: {1}),
      ]);
      final req2 = Request([
        RequestFilter(kinds: {2}),
      ]);

      pool.query(req1, source: RemoteSource(relays: {relayUrl}, stream: true));
      pool.query(req2, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for subscriptions
      await stateCapture.waitForSubscription(req1.subscriptionId);
      await stateCapture.waitForSubscription(req2.subscriptionId);

      // Dispose pool - should clean up all subscriptions
      pool.dispose();

      // No exception should be thrown
    });
  });

  group('Relay State in Subscription', () {
    test('should track activeRelayCount and totalRelayCount', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for EOSE (streaming phase)
      final state = await stateCapture.waitForEose(
        req.subscriptionId,
        relayUrl,
      );
      final subscription = state.subscriptions[req.subscriptionId];

      expect(subscription, isNotNull);
      expect(subscription!.totalRelayCount, equals(1));
      expect(subscription.activeRelayCount, equals(1));

      pool.unsubscribe(req);
    });
  });
}
