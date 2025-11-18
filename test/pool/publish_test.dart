import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/pool/state/pool_state_notifier.dart';
import 'package:purplebase/src/pool/state/relay_event_notifier.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for event publishing
void main() {
  late Process? relayProcess;
  late WebSocketPool pool;
  late PoolStateNotifier stateNotifier;
  late RelayEventNotifier eventNotifier;
  late StorageConfiguration config;
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

  test('should publish events and receive OK responses', () async {
    final note = await PartialNote('Test publish').signWith(signer);
    final event = note.toMap();

    final response = await pool.publish([
      event,
    ], source: RemoteSource(relayUrls: {relayUrl}));

    expect(response, isA<PublishRelayResponse>());
    expect(
      response.wrapped.results.containsKey(event['id']),
      isTrue,
      reason: 'Should have result for published event',
    );
  });

  test('should handle publish with empty events list', () async {
    final response = await pool.publish(
      [],
      source: RemoteSource(relayUrls: {relayUrl}),
    );

    expect(response, isA<PublishRelayResponse>());
    expect(
      response.wrapped.results,
      isEmpty,
      reason: 'Empty events should return empty results',
    );
  });

  test('should handle publish with empty relay URLs', () async {
    final note = await PartialNote('Test').signWith(signer);
    final event = note.toMap();

    final response = await pool.publish([
      event,
    ], source: RemoteSource(relayUrls: {}));

    expect(response, isA<PublishRelayResponse>());
    // When relayUrls is empty, it falls back to the default group
    expect(
      response.wrapped.results,
      isNotEmpty,
      reason: 'Empty relay URLs should fall back to default group',
    );
  });

  test('should publish multiple events', () async {
    final events = <Map<String, dynamic>>[];

    for (int i = 0; i < 3; i++) {
      final note = await PartialNote('Test event $i').signWith(signer);
      events.add(note.toMap());
    }

    final response = await pool.publish(
      events,
      source: RemoteSource(relayUrls: {relayUrl}),
    );

    expect(response.wrapped.results, hasLength(3));

    for (final event in events) {
      expect(
        response.wrapped.results.containsKey(event['id']),
        isTrue,
        reason: 'Should have result for each event',
      );
    }
  });

  test('should handle publish to offline relay', () async {
    const offlineRelay = 'ws://localhost:65535';

    final note = await PartialNote('Test').signWith(signer);
    final event = note.toMap();

    final response = await pool.publish([
      event,
    ], source: RemoteSource(relayUrls: {offlineRelay}));

    expect(response, isA<PublishRelayResponse>());

    // Should still return a response even if relay is offline
    final result = response.wrapped.results[event['id']];
    expect(result, isNotNull);
  });

  // Skip: Simplified pool no longer tracks in-progress publish operations
  // The publish functionality still works, just doesn't expose internal state
  test('should handle publish state tracking', () async {
    final note = await PartialNote('Test state tracking').signWith(signer);
    final event = note.toMap();

    final response = await pool.publish([event], source: RemoteSource(relayUrls: {relayUrl}));

    // Verify publish completes successfully
    expect(
      response.wrapped.results.containsKey(event['id']),
      isTrue,
      reason: 'Should complete publish operation',
    );
  }, skip: 'Simplified pool no longer tracks in-progress publishes');

  test('should publish to multiple relays', () async {
    // Start a second relay
    const relay2Port = 3338;
    const relay2Url = 'ws://localhost:$relay2Port';

    final relay2Process = await Process.start('test/support/test-relay', [
      '-port',
      relay2Port.toString(),
    ]);

    relay2Process.stdout.transform(utf8.decoder).listen((data) {});
    relay2Process.stderr.transform(utf8.decoder).listen((data) {});

    await Future.delayed(Duration(milliseconds: 500));

    try {
      final note = await PartialNote('Multi-relay test').signWith(signer);
      final event = note.toMap();

      final response = await pool.publish([
        event,
      ], source: RemoteSource(relayUrls: {relayUrl, relay2Url}));

      expect(response.wrapped.results.containsKey(event['id']), isTrue);

      final eventStates = response.wrapped.results[event['id']]!;
      expect(
        eventStates.length,
        greaterThanOrEqualTo(1),
        reason: 'Should have at least one relay response',
      );
    } finally {
      relay2Process.kill();
      await relay2Process.exitCode;
    }
  });
}
