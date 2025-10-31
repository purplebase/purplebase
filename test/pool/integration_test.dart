import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/pool/state/pool_state_notifier.dart';
import 'package:purplebase/src/pool/state/relay_event_notifier.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Basic test for the new WebSocketPool implementation
/// Tests against the test relay
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
    // Initialize models by initializing a temporary storage
    // This registers all the model types
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
    print('[test] Starting test relay on port $relayPort...');
    relayProcess = await Process.start('test/support/test-relay', [
      '-port',
      relayPort.toString(),
    ]);

    // Listen to relay output for debugging
    relayProcess!.stdout.transform(utf8.decoder).listen((data) {
      print('[relay-stdout] $data');
    });
    relayProcess!.stderr.transform(utf8.decoder).listen((data) {
      print('[relay-stderr] $data');
    });

    // Wait for relay to start
    await Future.delayed(Duration(milliseconds: 500));
    print('[test] Test relay started');
  });

  setUp(() async {
    // Create provider container
    container = ProviderContainer();

    // Create configuration
    config = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {relayUrl},
      },
      defaultRelayGroup: 'test',
    );

    // Create notifiers
    stateNotifier = PoolStateNotifier(
      throttleDuration: config.streamingBufferWindow,
    );
    eventNotifier = RelayEventNotifier();

    // Create pool
    pool = WebSocketPool(
      config: config,
      stateNotifier: stateNotifier,
      eventNotifier: eventNotifier,
    );

    // Create signer for test events
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
    // Stop test relay
    relayProcess?.kill();
    await relayProcess?.exitCode;
    print('[test] Test relay stopped');
  });

  test('should connect to relay and send subscription', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Send subscription
    await pool.send(req, relayUrls: {relayUrl});

    // Wait for connection and EOSE
    await Future.delayed(Duration(seconds: 2));

    // Check state
    final state = stateNotifier.currentState;
    expect(
      state.connections.containsKey(relayUrl),
      isTrue,
      reason: 'Should have connection state for relay',
    );

    // Check subscription state
    expect(
      state.subscriptions.containsKey(req.subscriptionId),
      isTrue,
      reason: 'Should have subscription state',
    );

    print('[test] ✓ Connected and subscribed successfully');

    // Clean up
    pool.unsubscribe(req);
  });

  test('should publish event and receive OK', () async {
    print('[test] Publishing event...');

    // Create and sign event
    final note = await PartialNote('Hello from new pool!').signWith(signer);
    final event = note.toMap();

    // Publish
    final response = await pool.publish([
      event,
    ], source: RemoteSource(relayUrls: {relayUrl}));

    print('[test] Publish response: ${response.wrapped.results}');

    // Verify response
    final eventId = event['id'] as String;
    expect(
      response.wrapped.results.containsKey(eventId),
      isTrue,
      reason: 'Should have result for published event',
    );
  });

  test('should query events', () async {
    print('[test] Querying events...');

    // First publish an event
    final note = await PartialNote('Test event for query').signWith(signer);
    final event = note.toMap();

    await pool.publish([event], source: RemoteSource(relayUrls: {relayUrl}));

    // Wait a moment for relay to process
    await Future.delayed(Duration(milliseconds: 200));

    // Query for events
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final events = await pool.query(
      req,
      source: RemoteSource(relayUrls: {relayUrl}),
    );

    print('[test] Received ${events.length} events');

    // Should receive the event we just published
    expect(events, isNotEmpty, reason: 'Should receive events from relay');
  });
}
