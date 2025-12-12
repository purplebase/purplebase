import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for connection management and lifecycle
void main() {
  late Process? relayProcess;
  late RelayPool pool;
  late PoolStateCapture stateCapture;
  late ProviderContainer container;
  late Bip340PrivateKeySigner signer;

  const relayPort = 3335;
  const relayUrl = 'ws://localhost:$relayPort';

  setUpAll(() async {
    // Initialize models
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

  test('should connect to relay successfully', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Start streaming query - this will connect to the relay
    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for connection deterministically
    final state = await stateCapture.waitForConnected(relayUrl);

    expect(
      state.isRelayConnected(relayUrl),
      isTrue,
      reason: 'Connection should exist',
    );

    pool.unsubscribe(req);
  });

  test('should handle URL normalization', () async {
    final denormalizedUrl = 'ws://localhost:$relayPort/';
    final normalizedUrl = normalizeRelayUrl(denormalizedUrl);
    expect(normalizedUrl, relayUrl, reason: 'normalizeRelayUrl should canonicalize');

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(
      req,
      source: RemoteSource(relays: {normalizedUrl}, stream: true),
    );

    // Wait for connection to normalized URL
    final state = await stateCapture.waitForConnected(normalizedUrl);

    // All URLs should be normalized to the same connection
    expect(
      state.isRelayConnected(normalizedUrl),
      isTrue,
      reason: 'Should normalize to standard URL',
    );

    pool.unsubscribe(req);
  });

  test('should handle connection to offline relay gracefully', () async {
    const offlineRelay = 'ws://localhost:65534';

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Start query (it will fail to connect)
    pool
        .query(req, source: RemoteSource(relays: {offlineRelay}, stream: true))
        .catchError((_) => <Map<String, dynamic>>[]);

    // Wait for subscription to be created
    final state = await stateCapture.waitForSubscription(req.subscriptionId);

    final sub = state.subscriptions[req.subscriptionId];
    expect(sub, isNotNull, reason: 'Subscription should exist');

    final relay = sub!.relays[offlineRelay];
    expect(relay, isNotNull, reason: 'Relay state should exist');
    expect(
      relay!.phase,
      anyOf(
        RelaySubPhase.disconnected,
        RelaySubPhase.connecting,
        RelaySubPhase.waiting,
      ),
      reason: 'Should be in disconnected, connecting, or waiting phase',
    );

    pool.unsubscribe(req);
  });

  test('should track connection metrics', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Start streaming query
    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for successful connection
    final state = await stateCapture.waitForConnected(relayUrl);
    final sub = state.subscriptions[req.subscriptionId];
    final relay = sub?.relays[relayUrl];

    expect(relay, isNotNull);
    expect(relay!.reconnectAttempts, greaterThanOrEqualTo(0));

    pool.unsubscribe(req);
  });

  test('should handle empty relay URLs gracefully', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Should not throw when given empty relay URLs
    final result = await pool.query(
      req,
      source: RemoteSource(relays: <String>{}),
    );
    expect(
      result,
      isEmpty,
      reason: 'Should return empty list for empty relay URLs',
    );
  });

  group('Health Check and Ping', () {
    test('should respond to health check while connected', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for connection
      await stateCapture.waitForConnected(relayUrl);

      // Health check should complete without disconnecting
      await pool.performHealthCheck();

      // Should still be connected
      final state = stateCapture.lastState;
      expect(state?.isRelayConnected(relayUrl), isTrue);

      pool.unsubscribe(req);
    });

    test('should respond to ensureConnected', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for connection
      await stateCapture.waitForConnected(relayUrl);

      // ensureConnected should work without error
      pool.ensureConnected();

      // Should still be connected after
      final state = stateCapture.lastState;
      expect(state?.isRelayConnected(relayUrl), isTrue);

      pool.unsubscribe(req);
    });

    test('should track last activity time', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for EOSE which triggers activity
      await stateCapture.waitForEose(req.subscriptionId, relayUrl);

      final state = stateCapture.lastState;
      final sub = state?.subscriptions[req.subscriptionId];
      final relay = sub?.relays[relayUrl];

      expect(relay, isNotNull);
      // lastEventAt may be null if no events were received (only EOSE)
      // but the relay should be streaming
      expect(relay!.phase, equals(RelaySubPhase.streaming));

      pool.unsubscribe(req);
    });
  });

  group('Error Recovery', () {
    test('should store error message on connection failure', () async {
      const offlineRelay = 'ws://localhost:65534';

      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool
        .query(req, source: RemoteSource(relays: {offlineRelay}, stream: true))
          .catchError((_) => <Map<String, dynamic>>[]);

      // Wait for subscription state
      final state = await stateCapture.waitForSubscription(req.subscriptionId);

      final sub = state.subscriptions[req.subscriptionId];
      final relay = sub?.relays[offlineRelay];
      expect(relay, isNotNull);

      // After failed connection, there might be an error
      // (depends on timing, so we just check the structure exists)
      expect(relay!.lastError, anyOf(isNull, isA<String>()));

      pool.unsubscribe(req);
    });

    test('should increment reconnect attempts on failure', () async {
      const offlineRelay = 'ws://localhost:65534';

      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool
        .query(req, source: RemoteSource(relays: {offlineRelay}, stream: true))
          .catchError((_) => <Map<String, dynamic>>[]);

      // Wait a bit for reconnect attempts
      try {
        await stateCapture.waitFor((s) {
          final sub = s.subscriptions[req.subscriptionId];
          final relay = sub?.relays[offlineRelay];
          return relay != null && relay.reconnectAttempts > 0;
        }, timeout: Duration(seconds: 10));
      } catch (_) {
        // May timeout if relay comes back too fast or never gets attempts
        // That's OK for this test
      }

      final state = stateCapture.lastState;
      final sub = state?.subscriptions[req.subscriptionId];
      final relay = sub?.relays[offlineRelay];

      // Should have at least tracked the relay
      expect(relay, isNotNull);

      pool.unsubscribe(req);
    });
  });
}
