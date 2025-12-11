import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for pool state management
void main() {
  late Process? relayProcess;
  late RelayPool pool;
  late PoolStateCapture stateCapture;
  late ProviderContainer container;
  late Bip340PrivateKeySigner signer;

  const relayPort = 3337;
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

  test('should emit state with correct structure', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for subscription to be established
    final state = await stateCapture.waitForSubscription(req.subscriptionId);

    expect(state.subscriptions, isA<Map<String, Subscription>>());
    expect(state.logs, isA<List<LogEntry>>());

    pool.unsubscribe(req);
  });

  test('should track relay connection state within subscription', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for connection
    final state = await stateCapture.waitForConnected(relayUrl);
    final sub = state.subscriptions[req.subscriptionId];
    final relay = sub?.relays[relayUrl];

    expect(sub, isNotNull, reason: 'Subscription should exist');
    expect(relay, isNotNull, reason: 'Relay state should exist');
    expect(
      relay!.phase,
      anyOf(RelaySubPhase.loading, RelaySubPhase.streaming),
      reason: 'Should be loading or streaming',
    );

    pool.unsubscribe(req);
  });

  test('should track subscription state', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for subscription
    final state = await stateCapture.waitForSubscription(req.subscriptionId);
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull, reason: 'Subscription should exist');
    expect(subscription!.id, equals(req.subscriptionId));
    expect(subscription.request, isNotNull);
    expect(subscription.relays, contains(relayUrl));
    expect(subscription.startedAt, isNotNull);

    pool.unsubscribe(req);
  });

  test('should have correct convenience getters', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for EOSE (streaming phase)
    final state = await stateCapture.waitForEose(req.subscriptionId, relayUrl);

    // Test convenience getters
    expect(state.connectedCount, equals(1));
    expect(state.isRelayConnected(relayUrl), isTrue);

    pool.unsubscribe(req);
  });

  test('should handle offline relay state', () async {
    const offlineRelay = 'ws://localhost:65534';

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Start query (will fail)
    pool
        .query(req, source: RemoteSource(relays: offlineRelay, stream: true))
        .catchError((_) => <Map<String, dynamic>>[]);

    // Wait for state to include the subscription
    final state = await stateCapture.waitForSubscription(req.subscriptionId);
    final sub = state.subscriptions[req.subscriptionId];
    final relay = sub?.relays[offlineRelay];

    expect(sub, isNotNull);
    expect(relay, isNotNull);
    expect(
      relay!.phase,
      anyOf(
        RelaySubPhase.disconnected,
        RelaySubPhase.connecting,
        RelaySubPhase.waiting,
      ),
    );

    pool.unsubscribe(req);
  });

  test('should track EOSE via streaming phase', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for EOSE (relay enters streaming phase)
    final state = await stateCapture.waitForEose(req.subscriptionId, relayUrl);
    final sub = state.subscriptions[req.subscriptionId];
    final relay = sub?.relays[relayUrl];

    expect(relay, isNotNull);
    expect(relay!.phase, equals(RelaySubPhase.streaming));

    pool.unsubscribe(req);
  });

  test('should include logs in state', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for EOSE
    await stateCapture.waitForEose(req.subscriptionId, relayUrl);

    pool.unsubscribe(req);

    // Wait for unsubscription (should log completion)
    final state = await stateCapture.waitForUnsubscribed(req.subscriptionId);

    // Logs should exist (completion is logged)
    expect(state.logs, isA<List<LogEntry>>());
  });

  test('Subscription should have statusText', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for EOSE to get meaningful status
    final state = await stateCapture.waitForEose(req.subscriptionId, relayUrl);
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(subscription!.statusText, isNotNull);
    // Should be something like "1/1 relays"
    expect(subscription.statusText, contains('relay'));

    pool.unsubscribe(req);
  });
}
