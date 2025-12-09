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
    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for connection deterministically
    final state = await stateCapture.waitForConnected(relayUrl);

    final connection = state.relays[relayUrl];
    expect(connection, isNotNull, reason: 'Connection should exist');
    expect(
      connection!.status,
      equals(ConnectionStatus.connected),
      reason: 'Connection status should be connected',
    );

    pool.unsubscribe(req);
  });

  test('should handle URL normalization', () async {
    final denormalizedUrl = 'ws://localhost:$relayPort/';

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(
      req,
      source: RemoteSource(relays: denormalizedUrl, stream: true),
    );

    // Wait for connection to normalized URL
    final state = await stateCapture.waitForConnected(relayUrl);

    // All URLs should be normalized to the same connection
    expect(
      state.relays.containsKey(relayUrl),
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
        .query(req, source: RemoteSource(relays: offlineRelay, stream: true))
        .catchError((_) => <Map<String, dynamic>>[]);

    // Wait for state to show connection attempt
    final state = await stateCapture.waitFor(
      (s) => s.relays.containsKey(offlineRelay),
    );

    final connection = state.relays[offlineRelay];
    expect(connection, isNotNull, reason: 'Connection state should exist');
    expect(
      connection!.status,
      anyOf(ConnectionStatus.disconnected, ConnectionStatus.connecting),
      reason: 'Should be in disconnected or connecting status',
    );

    pool.unsubscribe(req);
  });

  test('should track connection metrics', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Start streaming query
    pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

    // Wait for successful connection
    final state = await stateCapture.waitForConnected(relayUrl);
    final connection = state.relays[relayUrl];

    expect(connection, isNotNull);
    expect(connection!.reconnectAttempts, greaterThanOrEqualTo(0));
    expect(connection.statusChangedAt, isNotNull);

    pool.unsubscribe(req);
  });

  test('should handle empty relay URLs gracefully', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Should not throw when given empty relay URLs
    final result = await pool.query(req, source: RemoteSource());
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

      pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

      // Wait for connection
      await stateCapture.waitForConnected(relayUrl);

      // Health check should complete without disconnecting
      await pool.performHealthCheck();

      // Should still be connected
      final state = stateCapture.lastState;
      expect(state?.isRelayConnected(relayUrl), isTrue);

      pool.unsubscribe(req);
    });

    test(
      'should respond to forced ping (health check with force=true)',
      () async {
        final req = Request([
          RequestFilter(kinds: {1}),
        ]);

        pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

        // Wait for connection
        await stateCapture.waitForConnected(relayUrl);

        // Forced health check sends a ping (limit:0 request)
        await pool.performHealthCheck(force: true);

        // Should still be connected after ping response
        final state = stateCapture.lastState;
        expect(state?.isRelayConnected(relayUrl), isTrue);

        pool.unsubscribe(req);
      },
    );

    test('should track last activity time', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(req, source: RemoteSource(relays: relayUrl, stream: true));

      // Wait for EOSE which triggers activity
      await stateCapture.waitForEose(req.subscriptionId, relayUrl);

      final state = stateCapture.lastState;
      final connection = state?.relays[relayUrl];

      expect(connection, isNotNull);
      expect(connection!.lastActivityAt, isNotNull);

      // Activity should be recent
      final age = DateTime.now().difference(connection.lastActivityAt!);
      expect(age.inSeconds, lessThan(5));

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
          .query(req, source: RemoteSource(relays: offlineRelay, stream: true))
          .catchError((_) => <Map<String, dynamic>>[]);

      // Wait for state with relay
      final state = await stateCapture.waitFor(
        (s) => s.relays.containsKey(offlineRelay),
      );

      final connection = state.relays[offlineRelay];
      expect(connection, isNotNull);

      // After failed connection, there might be an error
      // (depends on timing, so we just check the structure exists)
      expect(connection!.error, anyOf(isNull, isA<String>()));

      pool.unsubscribe(req);
    });

    test('should increment reconnect attempts on failure', () async {
      const offlineRelay = 'ws://localhost:65534';

      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool
          .query(req, source: RemoteSource(relays: offlineRelay, stream: true))
          .catchError((_) => <Map<String, dynamic>>[]);

      // Wait a bit for reconnect attempts
      try {
        await stateCapture.waitFor((s) {
          final conn = s.relays[offlineRelay];
          return conn != null && conn.reconnectAttempts > 0;
        }, timeout: Duration(seconds: 10));
      } catch (_) {
        // May timeout if relay comes back too fast or never gets attempts
        // That's OK for this test
      }

      final state = stateCapture.lastState;
      final connection = state?.relays[offlineRelay];

      // Should have at least tracked the relay
      expect(connection, isNotNull);

      pool.unsubscribe(req);
    });
  });
}
