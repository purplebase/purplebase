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

    expect(state.relays, isA<Map<String, RelayState>>());
    expect(state.requests, isA<Map<String, RequestState>>());
    expect(state.timestamp, isNotNull);

    pool.unsubscribe(req);
  });

  test('should track relay connection state', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for connection
    final state = await stateCapture.waitForConnected(relayUrl);
    final connection = state.relays[relayUrl];

    expect(connection, isNotNull, reason: 'Connection should exist');
    expect(connection!.url, equals(relayUrl));
    expect(connection.status, equals(ConnectionStatus.connected));
    expect(connection.statusChangedAt, isNotNull);

    pool.unsubscribe(req);
  });

  test('should track subscription state', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for subscription
    final state = await stateCapture.waitForSubscription(req.subscriptionId);
    final subscription = state.requests[req.subscriptionId];

    expect(subscription, isNotNull, reason: 'Subscription should exist');
    expect(subscription!.subscriptionId, equals(req.subscriptionId));
    expect(subscription.filters, isNotEmpty);
    expect(subscription.targetRelays, contains(relayUrl));
    expect(subscription.startedAt, isNotNull);

    pool.unsubscribe(req);
  });

  test('should have correct convenience getters', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for connection
    final state = await stateCapture.waitForConnected(relayUrl);

    // Test convenience getters
    expect(state.connectedCount, equals(1));
    expect(state.disconnectedCount, greaterThanOrEqualTo(0));
    expect(state.connectingCount, greaterThanOrEqualTo(0));
    expect(state.isRelayConnected(relayUrl), isTrue);

    pool.unsubscribe(req);
  });

  test('should handle offline relay state', () async {
    const offlineRelay = 'ws://localhost:65534';

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Start query (will fail)
    pool.query(req, source: RemoteSource(relays: offlineRelay, stream: true)).catchError((_) => <Map<String, dynamic>>[]);

    // Wait for state to include the offline relay
    final state = await stateCapture.waitFor(
      (s) => s.relays.containsKey(offlineRelay),
    );
    final connection = state.relays[offlineRelay];

    expect(connection, isNotNull);
    expect(
      connection!.status,
      anyOf(ConnectionStatus.disconnected, ConnectionStatus.connecting),
    );

    pool.unsubscribe(req);
  });

  test('should track EOSE in subscription state', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for EOSE
    final state = await stateCapture.waitForEose(req.subscriptionId, relayUrl);
    final subscription = state.requests[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(subscription!.eoseReceived, contains(relayUrl));

    pool.unsubscribe(req);
  });

  test('should include lastChange for debugging', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for any state with lastChange
    final state = await stateCapture.waitFor((s) => s.lastChange != null);
    expect(state.lastChange, isNotNull);

    pool.unsubscribe(req);
  });

  test('RequestState should have statusText', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for EOSE to get meaningful status
    final state = await stateCapture.waitForEose(req.subscriptionId, relayUrl);
    final subscription = state.requests[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(subscription!.statusText, isNotNull);
    // Should be something like "1/1 EOSE" or "streaming"
    expect(subscription.statusText, anyOf(contains('EOSE'), equals('streaming')));

    pool.unsubscribe(req);
  });
}
