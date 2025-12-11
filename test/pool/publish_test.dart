import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for publish operations
void main() {
  late Process? relayProcess;
  late RelayPool pool;
  late ProviderContainer container;
  late Bip340PrivateKeySigner signer;

  const relayPort = 3339;
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

    final config = testConfig(relayUrl);

    pool = RelayPool(
      config: config,
      onStateChange: (_) {},
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

  test('should publish event successfully with acceptance confirmation', () async {
    final note = await PartialNote(
      'test publish ${DateTime.now().millisecondsSinceEpoch}',
    ).signWith(signer);

    final response = await pool.publish(
      [note.toMap()],
      source: RemoteSource(relays: {relayUrl}),
    );

    // Verify response contains the event ID
    expect(response.wrapped.results, isNotEmpty, reason: 'Should have results');
    expect(response.wrapped.results.containsKey(note.id), isTrue, reason: 'Should contain event ID');

    // Verify event was accepted by the relay
    final eventStates = response.wrapped.results[note.id]!;
    expect(eventStates, isNotEmpty, reason: 'Should have relay responses');
    expect(eventStates.first.accepted, isTrue, reason: 'Event should be accepted');
    expect(eventStates.first.relayUrl, equals(relayUrl), reason: 'Should be from correct relay');
  });

  test('should return empty response for empty events', () async {
    final response = await pool.publish(
      [],
      source: RemoteSource(relays: {relayUrl}),
    );

    expect(response.wrapped.results, isEmpty, reason: 'No events = no results');
  });

  test('should use resolved relay URLs', () async {
    final note = await PartialNote('test fallback ${DateTime.now().millisecondsSinceEpoch}').signWith(signer);

    // Pool receives already-resolved relay URLs from storage layer
    final response = await pool.publish(
      [note.toMap()],
      source: RemoteSource(relays: {relayUrl}),
    );

    expect(response.wrapped.results, isNotEmpty, reason: 'Should publish to resolved relay');
    expect(response.wrapped.results.containsKey(note.id), isTrue);
  });

  test('should publish multiple events with all accepted', () async {
    final notes = await Future.wait([
      PartialNote('test 1').signWith(signer),
      PartialNote('test 2').signWith(signer),
      PartialNote('test 3').signWith(signer),
    ]);

    final response = await pool.publish(
      notes.map((n) => n.toMap()).toList(),
      source: RemoteSource(relays: {relayUrl}),
    );

    // Verify all events have results
    expect(response.wrapped.results.length, equals(3), reason: 'Should have 3 results');

    // Verify each event was accepted
    for (final note in notes) {
      expect(
        response.wrapped.results.containsKey(note.id),
        isTrue,
        reason: 'Should contain event ID ${note.id}',
      );
      final eventStates = response.wrapped.results[note.id]!;
      expect(eventStates.first.accepted, isTrue, reason: 'Event ${note.id} should be accepted');
    }
  });
}
