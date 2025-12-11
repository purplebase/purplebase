import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Integration tests for the pool
void main() {
  late Process? relayProcess;
  late RelayPool pool;
  late PoolStateCapture stateCapture;
  late List<Map<String, dynamic>> receivedEvents;
  late ProviderContainer container;
  late Bip340PrivateKeySigner signer;

  const relayPort = 3340;
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
    receivedEvents = [];

    final config = testConfig(relayUrl);

    pool = RelayPool(
      config: config,
      onStateChange: stateCapture.onState,
      onEvents: ({required req, required events, required relaysForIds}) {
        receivedEvents.addAll(events);
      },
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

  test('should publish and query back event', () async {
    // Publish an event
    final note = await PartialNote(
      'integration test ${DateTime.now().millisecondsSinceEpoch}',
    ).signWith(signer);
    final publishResponse =
        await pool.publish([note.toMap()], source: RemoteSource(relays: {relayUrl}));

    // Verify publish was accepted
    expect(publishResponse.wrapped.results, isNotEmpty);
    expect(publishResponse.wrapped.results[note.id]?.first.accepted, isTrue);

    // Query for it
    final req = Request([
      RequestFilter(ids: {note.id}),
    ]);
    final result = await pool.query(req, source: RemoteSource(relays: {relayUrl}));

    // Should find the event with correct content
    expect(result, isNotEmpty, reason: 'Should find published event');
    expect(result.first['id'], equals(note.id));
    expect(result.first['content'], contains('integration test'));
  });

  test('should handle health check', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

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

  test('should handle ensureConnected', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for connection
    await stateCapture.waitForConnected(relayUrl);

    // ensureConnected should work
    pool.ensureConnected();

    // Should still be connected
    final state = stateCapture.lastState;
    expect(state, isNotNull);
    expect(state!.isRelayConnected(relayUrl), isTrue);

    pool.unsubscribe(req);
  });

  test('should clean up connections on dispose', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for connection
    await stateCapture.waitForConnected(relayUrl);

    // Verify connected before dispose
    expect(stateCapture.lastState?.isRelayConnected(relayUrl), isTrue);

    pool.dispose();

    // After dispose, pool should be cleaned up (no way to verify externally,
    // but at least no exceptions should be thrown)
  });
}
