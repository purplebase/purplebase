import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for query operations
void main() {
  late Process? relayProcess;
  late RelayPool pool;
  late PoolStateCapture stateCapture;
  late List<Map<String, dynamic>> receivedEvents;
  late ProviderContainer container;
  late Bip340PrivateKeySigner signer;

  const relayPort = 3338;
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

  test('should execute foreground query and return published event', () async {
    // First publish an event so we have something to query
    final note = await PartialNote(
      'foreground query test ${DateTime.now().millisecondsSinceEpoch}',
    ).signWith(signer);
    await pool.publish([note.toMap()], source: RemoteSource(relays: {relayUrl}));

    final req = Request([
      RequestFilter(kinds: {1}, ids: {note.id}),
    ]);

    final result = await pool.query(
      req,
      source: RemoteSource(relays: {relayUrl}),
    );

    // Verify we got the specific event back
    expect(result, isNotEmpty, reason: 'Should return published event');
    expect(result.first['id'], equals(note.id), reason: 'Should return correct event ID');
    expect(result.first['content'], contains('foreground query test'));
  });

  test('should execute background query', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    final result = await pool.query(
      req,
      source: RemoteSource(relays: {relayUrl}, background: true),
    );

    // Background queries return empty immediately
    expect(result, isEmpty);

    // Wait for subscription to be created
    final state = await stateCapture.waitForSubscription(req.subscriptionId);

    expect(state.subscriptions.containsKey(req.subscriptionId), isTrue);

    pool.unsubscribe(req);
  });

  test('should execute streaming query', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Start streaming query
    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    // Wait for subscription and EOSE
    final state = await stateCapture.waitForEose(req.subscriptionId, relayUrl);

    final subscription = state.subscriptions[req.subscriptionId];
    expect(subscription, isNotNull);
    expect(subscription!.stream, isTrue);

    pool.unsubscribe(req);
  });

  test('should return empty for empty filters', () async {
    final req = Request(<RequestFilter<Note>>[]);

    final result = await pool.query(
      req,
      source: RemoteSource(relays: {relayUrl}),
    );

    expect(result, isEmpty);
  });

  test('should return empty for empty relay URLs', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    final result = await pool.query(
      req,
      source: RemoteSource(relays: <String>{}),
    );

    expect(result, isEmpty);
  });

  test('should call onEvents callback with correct event data', () async {
    // First publish an event
    final note = await PartialNote(
      'callback test ${DateTime.now().millisecondsSinceEpoch}',
    ).signWith(signer);
    await pool.publish([note.toMap()], source: RemoteSource(relays: {relayUrl}));

    // Then query for it
    final req = Request([
      RequestFilter(kinds: {1}, ids: {note.id}),
    ]);

    await pool.query(req, source: RemoteSource(relays: {relayUrl}));

    // Verify callback received the event with correct data
    expect(receivedEvents, isNotEmpty, reason: 'onEvents should be called');
    final matchingEvent = receivedEvents.where((e) => e['id'] == note.id);
    expect(matchingEvent, isNotEmpty, reason: 'Should receive the published event');
    expect(matchingEvent.first['content'], contains('callback test'));
  });
}
