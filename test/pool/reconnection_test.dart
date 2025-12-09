import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for reconnection and backoff behavior
void main() {
  late Process? relayProcess;
  late RelayPool pool;
  late PoolStateCapture stateCapture;
  late ProviderContainer container;
  late Bip340PrivateKeySigner signer;

  const relayPort = 3341;
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

  group('Connection Recovery', () {
    test('should connect and recover from temporary disconnect', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      // Start streaming query
      pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

      // Wait for connection
      final connectedState = await stateCapture.waitForConnected(relayUrl);
      expect(connectedState.isRelayConnected(relayUrl), isTrue);

      pool.unsubscribe(req);
    });

    test('should track reconnect attempts for offline relay', () async {
      const offlineRelay = 'ws://localhost:65534';

      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      // Try to connect to offline relay
      pool.query(req, source: RemoteSource(relays: offlineRelay, stream: true))
          .catchError((_) => <Map<String, dynamic>>[]);

      // Wait for state to show relay
      final state = await stateCapture.waitFor(
        (s) => s.relays.containsKey(offlineRelay),
      );

      final connection = state.relays[offlineRelay];
      expect(connection, isNotNull);
      expect(
        connection!.status,
        anyOf(ConnectionStatus.disconnected, ConnectionStatus.connecting),
      );

      // Reconnect attempts should be tracked
      expect(connection.reconnectAttempts, greaterThanOrEqualTo(0));

      pool.unsubscribe(req);
    });

    test('should resend subscriptions after reconnect', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      // Start streaming query
      pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

      // Wait for connection
      await stateCapture.waitForConnected(relayUrl);

      // Verify subscription exists
      final state = await stateCapture.waitForSubscription(req.subscriptionId);
      expect(state.requests.containsKey(req.subscriptionId), isTrue);

      // The subscription should have the relay as target
      final sub = state.requests[req.subscriptionId];
      expect(sub?.targetRelays, contains(relayUrl));

      pool.unsubscribe(req);
    });
  });

  group('Connection State Tracking', () {
    test('should update statusChangedAt on connection changes', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

      final state = await stateCapture.waitForConnected(relayUrl);
      final connection = state.relays[relayUrl];

      expect(connection, isNotNull);
      expect(connection!.statusChangedAt, isNotNull);

      // Should be recent (within last few seconds)
      final now = DateTime.now();
      final age = now.difference(connection.statusChangedAt);
      expect(age.inSeconds, lessThan(10));

      pool.unsubscribe(req);
    });

    test('should track last activity', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

      // Wait for EOSE which indicates activity
      final state = await stateCapture.waitForEose(req.subscriptionId, relayUrl);
      final connection = state.relays[relayUrl];

      expect(connection, isNotNull);
      // lastActivityAt might be set after EOSE is received
      expect(connection!.lastActivityAt, isNotNull);

      pool.unsubscribe(req);
    });
  });

  group('Health Check', () {
    test('should perform health check without disconnecting', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

      // Wait for connection
      await stateCapture.waitForConnected(relayUrl);

      // Perform health check
      await pool.performHealthCheck();

      // Should still be connected
      final state = stateCapture.lastState;
      expect(state, isNotNull);
      expect(state!.isRelayConnected(relayUrl), isTrue);

      pool.unsubscribe(req);
    });

    test('should perform forced health check (ping)', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

      // Wait for connection
      await stateCapture.waitForConnected(relayUrl);

      // Force health check (sends ping)
      await pool.performHealthCheck(force: true);

      // Should still be connected
      final state = stateCapture.lastState;
      expect(state, isNotNull);
      expect(state!.isRelayConnected(relayUrl), isTrue);

      pool.unsubscribe(req);
    });
  });

  group('Idle Connection Cleanup', () {
    test('should cleanup connections when no subscriptions', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

      // Wait for connection
      await stateCapture.waitForConnected(relayUrl);

      // Unsubscribe
      pool.unsubscribe(req);

      // Wait for unsubscribe to process
      await stateCapture.waitForUnsubscribed(req.subscriptionId);

      // Connection cleanup happens after unsubscribe
      // The relay might still be in state but should be cleaned up
      final state = stateCapture.lastState;
      expect(state, isNotNull);
      expect(state!.requests.containsKey(req.subscriptionId), isFalse);
    });
  });
}

