import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/pool/state/pool_state_notifier.dart';
import 'package:purplebase/src/pool/state/relay_event_notifier.dart';
import 'package:purplebase/src/pool/state/connection_phase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for connection management and lifecycle
void main() {
  late Process? relayProcess;
  late WebSocketPool pool;
  late PoolStateNotifier stateNotifier;
  late RelayEventNotifier eventNotifier;
  late StorageConfiguration config;
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
      relayGroups: {
        'temp': {'wss://temp.com'},
      },
      defaultRelayGroup: 'temp',
    );
    await tempContainer.read(initializationProvider(tempConfig).future);

    // Start test relay
    relayProcess = await Process.start('test/support/test-relay', [
      '-port',
      relayPort.toString(),
    ]);

    relayProcess!.stdout.transform(utf8.decoder).listen((data) {
      // Suppress output for cleaner test results
    });
    relayProcess!.stderr.transform(utf8.decoder).listen((data) {
      // Suppress output for cleaner test results
    });

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
      idleTimeout: Duration(seconds: 30),
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

  test('should connect to relay successfully', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(seconds: 1));

    final state = stateNotifier.currentState;
    final connection = state.connections[relayUrl];

    expect(connection, isNotNull, reason: 'Connection should exist');
    expect(
      connection!.phase,
      isA<Connected>(),
      reason: 'Connection phase should be Connected',
    );

    pool.unsubscribe(req);
  });

  test('should handle URL normalization', () async {
    final denormalizedUrls = {
      'ws://localhost:$relayPort/',
      'ws://localhost:$relayPort//',
    };

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: denormalizedUrls);
    await Future.delayed(Duration(seconds: 1));

    final state = stateNotifier.currentState;

    // All URLs should be normalized to the same connection
    expect(
      state.connections.containsKey(relayUrl),
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

    await pool.send(req, relayUrls: {offlineRelay});
    await Future.delayed(Duration(seconds: 1));

    final state = stateNotifier.currentState;
    final connection = state.connections[offlineRelay];

    // Connection should exist but be in disconnected or connecting phase
    expect(connection, isNotNull, reason: 'Connection state should exist');
    expect(
      connection!.phase,
      anyOf(isA<Disconnected>(), isA<Connecting>()),
      reason: 'Should be in disconnected or connecting phase',
    );

    pool.unsubscribe(req);
  });

  test('should track connection metrics', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(seconds: 1));

    final state = stateNotifier.currentState;
    final connection = state.connections[relayUrl];

    expect(connection, isNotNull);
    expect(connection!.reconnectAttempts, equals(0));
    expect(connection.lastMessageAt, isNotNull);
    expect(connection.phaseStartedAt, isNotNull);

    pool.unsubscribe(req);
  });

  test('should handle idle connection cleanup', () async {
    final shortIdleConfig = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {relayUrl},
      },
      defaultRelayGroup: 'test',
      idleTimeout: Duration(milliseconds: 100),
    );

    final idlePool = WebSocketPool(
      config: shortIdleConfig,
      stateNotifier: stateNotifier,
      eventNotifier: eventNotifier,
    );

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);
    await idlePool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 200));

    // Unsubscribe to make connection idle
    idlePool.unsubscribe(req);
    await Future.delayed(Duration(milliseconds: 300));

    final state = stateNotifier.currentState;

    // Connection should be cleaned up or disconnected
    final connection = state.connections[relayUrl];
    if (connection != null) {
      expect(
        connection.phase,
        isA<Disconnected>(),
        reason: 'Idle connection should be disconnected',
      );
    }

    idlePool.dispose();
  });

  test('should handle empty relay URLs gracefully', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Should not throw when given empty relay URLs
    expect(
      () async => await pool.send(req, relayUrls: {}),
      returnsNormally,
      reason: 'Should handle empty relay URLs without error',
    );
  });
}
