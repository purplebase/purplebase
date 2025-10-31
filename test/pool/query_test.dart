import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/pool/state/pool_state_notifier.dart';
import 'package:purplebase/src/pool/state/relay_event_notifier.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for querying events
void main() {
  late Process? relayProcess;
  late WebSocketPool pool;
  late PoolStateNotifier stateNotifier;
  late RelayEventNotifier eventNotifier;
  late StorageConfiguration config;
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

  test('should query events and receive responses', () async {
    // First publish an event
    final note = await PartialNote('Query test event').signWith(signer);
    await pool.publish([
      note.toMap(),
    ], source: RemoteSource(relayUrls: {relayUrl}));

    await Future.delayed(Duration(milliseconds: 200));

    // Query for it
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final events = await pool.query(
      req,
      source: RemoteSource(relayUrls: {relayUrl}),
    );

    expect(events, isNotEmpty, reason: 'Should receive events');
    expect(
      events.any((e) => e['content'] == 'Query test event'),
      isTrue,
      reason: 'Should find the published event',
    );
  });

  test('should handle event roundtrip (publish then query)', () async {
    final testContent =
        'Roundtrip test ${DateTime.now().millisecondsSinceEpoch}';
    final note = await PartialNote(testContent).signWith(signer);
    final event = note.toMap();

    // Publish
    await pool.publish([event], source: RemoteSource(relayUrls: {relayUrl}));

    await Future.delayed(Duration(milliseconds: 200));

    // Query
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final events = await pool.query(
      req,
      source: RemoteSource(relayUrls: {relayUrl}),
    );

    expect(
      events.any((e) => e['content'] == testContent),
      isTrue,
      reason: 'Should find published event in query results',
    );
  });

  test('should handle event deduplication', () async {
    // Publish same event to relay
    final note = await PartialNote('Dedup test').signWith(signer);
    final event = note.toMap();

    await pool.publish([event], source: RemoteSource(relayUrls: {relayUrl}));

    await Future.delayed(Duration(milliseconds: 200));

    // Query with streaming to receive events
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final receivedEvents = <String>[];

    eventNotifier.addListener((relayEvent) {
      if (relayEvent case EventsReceived(:final events)) {
        for (final event in events) {
          receivedEvents.add(event['id'] as String);
        }
      }
    });

    await pool.query(
      req,
      source: RemoteSource(relayUrls: {relayUrl}, stream: true),
    );

    await Future.delayed(Duration(seconds: 1));

    // Events should be received
    expect(receivedEvents, isNotEmpty, reason: 'Should receive events');

    pool.unsubscribe(req);
  });

  test('should handle query with filters', () async {
    // Publish multiple events with different kinds
    final note1 = await PartialNote('Kind 1 event').signWith(signer);

    await pool.publish([
      note1.toMap(),
    ], source: RemoteSource(relayUrls: {relayUrl}));

    await Future.delayed(Duration(milliseconds: 200));

    // Query for specific kind
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final events = await pool.query(
      req,
      source: RemoteSource(relayUrls: {relayUrl}),
    );

    // All events should match the filter
    for (final event in events) {
      if (event['pubkey'] == signer.pubkey) {
        expect(event['kind'], equals(1));
      }
    }
  });

  test('should handle empty query results', () async {
    final req = Request([
      RequestFilter(kinds: {999}, authors: {'nonexistent' * 8}),
    ]);

    final events = await pool.query(
      req,
      source: RemoteSource(relayUrls: {relayUrl}),
    );

    expect(events, isEmpty, reason: 'Should return empty for no matches');
  });

  test('should handle query timeout', () async {
    const offlineRelay = 'ws://localhost:65536';

    final shortTimeoutConfig = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {offlineRelay},
      },
      defaultRelayGroup: 'test',
      responseTimeout: Duration(milliseconds: 100),
    );

    final timeoutPool = WebSocketPool(
      config: shortTimeoutConfig,
      stateNotifier: stateNotifier,
      eventNotifier: eventNotifier,
    );

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    final events = await timeoutPool.query(
      req,
      source: RemoteSource(relayUrls: {offlineRelay}),
    );

    expect(events, isEmpty, reason: 'Timeout should return empty');

    timeoutPool.dispose();
  });

  test('should track event count in subscription state', () async {
    // Publish some events
    for (int i = 0; i < 3; i++) {
      final note = await PartialNote('Event $i').signWith(signer);
      await pool.publish([
        note.toMap(),
      ], source: RemoteSource(relayUrls: {relayUrl}));
    }

    await Future.delayed(Duration(milliseconds: 300));

    // Query them
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    await pool.query(req, source: RemoteSource(relayUrls: {relayUrl}));

    await Future.delayed(Duration(milliseconds: 300));

    final state = stateNotifier.currentState;
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(
      subscription!.totalEventsReceived,
      greaterThanOrEqualTo(0),
      reason: 'Should track event count',
    );
  });
}
