import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/pool/state/pool_state_notifier.dart';
import 'package:purplebase/src/pool/state/relay_event_notifier.dart';
import 'package:purplebase/src/pool/state/subscription_phase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for subscription management
void main() {
  late Process? relayProcess;
  late WebSocketPool pool;
  late PoolStateNotifier stateNotifier;
  late RelayEventNotifier eventNotifier;
  late StorageConfiguration config;
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
      relayGroups: {
        'temp': {'wss://temp.com'},
      },
      defaultRelayGroup: 'temp',
    );
    await tempContainer.read(initializationProvider(tempConfig).future);

    relayProcess = await Process.start('test/support/test-relay', [
      '-port',
      relayPort.toString(),
    ]);

    relayProcess!.stdout.transform(utf8.decoder).listen((data) {});
    relayProcess!.stderr.transform(utf8.decoder).listen((data) {});

    await Future.delayed(Duration(milliseconds: 500));
  });

  setUp(() async {
    container = ProviderContainer();

    config = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {relayUrl},
      },
      defaultRelayGroup: 'test',
      responseTimeout: Duration(seconds: 5),
      streamingBufferWindow: Duration(milliseconds: 100),
    );

    stateNotifier = PoolStateNotifier(
      throttleDuration: config.streamingBufferWindow,
    );
    eventNotifier = RelayEventNotifier();

    pool = WebSocketPool(
      config: config,
      stateNotifier: stateNotifier,
      eventNotifier: eventNotifier,
    );

    signer = Bip340PrivateKeySigner(
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      container.read(refProvider),
    );
    await signer.signIn();
  });

  tearDown(() {
    pool.dispose();
  });

  tearDownAll(() async {
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  test('should create subscription with send()', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    final state = stateNotifier.currentState;
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull, reason: 'Subscription should exist');
    expect(
      subscription!.subscriptionId,
      equals(req.subscriptionId),
      reason: 'Subscription ID should match',
    );
    expect(
      subscription.relayStatus.containsKey(relayUrl),
      isTrue,
      reason: 'Should have relay status',
    );

    pool.unsubscribe(req);
  });

  test('should handle query with background=true', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    final result = await pool.query(
      req,
      source: RemoteSource(relayUrls: {relayUrl}, background: true),
    );

    // Background queries return empty immediately
    expect(result, isEmpty, reason: 'Background query should return empty');

    await Future.delayed(Duration(milliseconds: 500));

    // But subscription should be created
    final state = stateNotifier.currentState;
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
    pool.query(req, source: RemoteSource(relayUrls: {relayUrl}, stream: true));

    await Future.delayed(Duration(milliseconds: 500));

    final state = stateNotifier.currentState;
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(
      subscription!.phase,
      anyOf(SubscriptionPhase.eose, SubscriptionPhase.streaming),
      reason: 'Subscription should be in eose or streaming phase',
    );

    pool.unsubscribe(req);
  });

  test('should track subscription state correctly', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    final state = stateNotifier.currentState;
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(subscription!.totalEventsReceived, greaterThanOrEqualTo(0));
    expect(subscription.startedAt, isNotNull);
    expect(subscription.relayStatus, isNotEmpty);

    pool.unsubscribe(req);
  });

  test('should handle send with empty relay URLs', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    expect(
      () async => await pool.send(req, relayUrls: {}),
      returnsNormally,
      reason: 'Should handle empty relay URLs gracefully',
    );
  });

  test('should handle multiple subscriptions', () async {
    final req1 = Request([
      RequestFilter(kinds: {1}),
    ]);
    final req2 = Request([
      RequestFilter(kinds: {2}),
    ]);

    await pool.send(req1, relayUrls: {relayUrl});
    await pool.send(req2, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    final state = stateNotifier.currentState;

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

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    pool.unsubscribe(req);
    await Future.delayed(Duration(milliseconds: 200));

    final state = stateNotifier.currentState;

    // Subscription should be removed or marked as inactive
    final subscription = state.subscriptions[req.subscriptionId];
    if (subscription != null) {
      // If it still exists, it should have no active relays
      expect(
        subscription.relayStatus.values.every(
          (s) => s.phase is! SubscriptionActive,
        ),
        isTrue,
        reason: 'Unsubscribed subscription should have no active relays',
      );
    }
  });
}
