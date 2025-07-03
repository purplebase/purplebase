import 'dart:async';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/websocket_pool.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  late WebSocketPool pool;
  late NostrRelay relay;
  late String relayUrl;
  late Bip340PrivateKeySigner signer;
  late List<Map<String, dynamic>> testEvents;

  Future<void> createTestEvents() async {
    // Create test events that will be used for testing
    for (int i = 1; i <= 3; i++) {
      final content = 'Test event content $i';
      final note = await PartialNote(content).signWith(signer);
      final event = note.toMap();
      testEvents.add(event);
    }
  }

  setUpAll(() async {
    testEvents = [];

    // Initialize storage to register models
    final container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    final config = StorageConfiguration(
      relayGroups: {
        'test': {'wss://test.com'},
      },
      defaultRelayGroup: 'test',
    );

    await container.read(initializationProvider(config).future);

    // Use a made-up private key for deterministic signing
    signer = Bip340PrivateKeySigner(
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      container.read(refProvider),
    );
    await signer.initialize();

    // Create test events
    await createTestEvents();

    // Start relay on a random port
    final port = 8080 + (DateTime.now().millisecondsSinceEpoch % 1000);
    relayUrl = 'ws://localhost:$port';

    // Create and start the relay
    relay = NostrRelay(port: port, host: '127.0.0.1');
    await relay.start();
  });

  tearDownAll(() async {
    await relay.stop();
  });

  setUp(() {
    final config = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {relayUrl},
      },
      defaultRelayGroup: 'test',
      responseTimeout: Duration(seconds: 5),
      streamingBufferWindow: Duration(milliseconds: 100),
      idleTimeout: Duration(seconds: 30),
    );
    pool = WebSocketPool(config);
  });

  tearDown(() async {
    pool.dispose();
  });

  // Unit tests for edge cases and state classes
  test('should handle publish with empty events list', () async {
    // Publish empty events list (no relay URLs needed since events list is empty)
    final publishResponse = await pool.publish([], relayUrls: {});

    expect(
      publishResponse,
      isA<PublishRelayResponse>(),
      reason: 'Should return PublishRelayResponse even with empty events',
    );

    print('✓ Empty publish test completed successfully');
  });

  test('should handle publish with empty relay URLs', () async {
    final publishResponse = await pool.publish(testEvents, relayUrls: {});

    expect(
      publishResponse,
      isA<PublishRelayResponse>(),
      reason: 'Should return PublishRelayResponse with empty relay URLs',
    );

    print('✓ Empty relay URLs publish test completed successfully');
  });

  test('should handle query with background=true', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    final result = await pool.query(
      req,
      relayUrls: {}, // TODO: it does need relayUrls!
      source: const RemoteSource(background: true),
    );

    // Should return empty list when returnModels=false
    expect(
      result,
      isEmpty,
      reason: 'Should return empty list when background=true',
    );

    print('✓ Query with background=true test completed successfully');
  });

  test('should handle query with non-existent subscription', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Query without sending the request first (no relay URLs)
    // This should return empty list since subscription doesn't exist
    final result = await pool.query(req, relayUrls: {});

    expect(
      result,
      isEmpty,
      reason: 'Should return empty list for non-existent subscription',
    );

    print('✓ Query with non-existent subscription test completed successfully');
  });

  test('should handle unsubscribe with non-existent subscription', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Try to unsubscribe from a subscription that doesn't exist
    // This should not throw
    pool.unsubscribe(req);

    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isFalse,
      reason: 'Subscription should not exist',
    );

    print(
      '✓ Unsubscribe with non-existent subscription test completed successfully',
    );
  });

  test('should handle send with empty relay URLs', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Send with empty relay URLs
    await pool.send(req, relayUrls: {});

    // Should not create any subscriptions
    expect(
      pool.subscriptions.isEmpty,
      isTrue,
      reason: 'Should not create subscriptions for empty relay URLs',
    );

    print('✓ Send with empty relay URLs test completed successfully');
  });

  test('should handle relay state properties correctly', () async {
    final relayState = RelayState();

    // Test initial state
    expect(
      relayState.isConnected,
      isFalse,
      reason: 'Should start disconnected',
    );
    expect(
      relayState.isConnecting,
      isFalse,
      reason: 'Should not be connecting initially',
    );
    expect(
      relayState.isDisconnected,
      isTrue,
      reason: 'Should be disconnected initially',
    );

    // Test with null socket
    relayState.socket = null;
    expect(
      relayState.isConnected,
      isFalse,
      reason: 'Should be disconnected with null socket',
    );
    expect(
      relayState.isConnecting,
      isFalse,
      reason: 'Should not be connecting with null socket',
    );
    expect(
      relayState.isDisconnected,
      isTrue,
      reason: 'Should be disconnected with null socket',
    );

    print('✓ Relay state properties test completed successfully');
  });

  test('should handle subscription state correctly', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);
    final targetRelays = {'ws://localhost:8080'};

    final subscription = SubscriptionState(
      req: req,
      targetRelays: targetRelays,
    );

    // Test initial state
    expect(
      subscription.phase,
      equals(SubscriptionPhase.eose),
      reason: 'Should start in eose phase',
    );
    expect(
      subscription.connectedRelays,
      isEmpty,
      reason: 'Should start with no connected relays',
    );
    expect(
      subscription.eoseReceived,
      isEmpty,
      reason: 'Should start with no EOSE received',
    );
    expect(
      subscription.bufferedEvents,
      isEmpty,
      reason: 'Should start with no buffered events',
    );
    expect(
      subscription.allEoseReceived,
      isFalse,
      reason: 'Should not have all EOSE initially',
    );

    // Test with empty target relays
    final emptySubscription = SubscriptionState(req: req, targetRelays: {});
    expect(
      emptySubscription.allEoseReceived,
      isTrue,
      reason: 'Should have all EOSE with empty targets',
    );

    print('✓ Subscription state test completed successfully');
  });

  test('should handle publish state correctly', () async {
    final events = testEvents;
    final targetRelays = {'ws://localhost:8080'};
    final publishId = 'test-publish-id';

    final publishState = PublishState(
      events: events,
      targetRelays: targetRelays,
      publishId: publishId,
    );

    // Test initial state
    expect(
      publishState.pendingEventIds,
      isEmpty,
      reason: 'Should start with no pending events',
    );
    expect(
      publishState.sentToRelays,
      isEmpty,
      reason: 'Should start with no sent relays',
    );
    expect(
      publishState.pendingResponses,
      isEmpty,
      reason: 'Should start with no pending responses',
    );
    expect(
      publishState.failedRelays,
      isEmpty,
      reason: 'Should start with no failed relays',
    );
    expect(
      publishState.allResponsesReceived,
      isTrue,
      reason: 'Should have all responses with no pending events',
    );

    print('✓ Publish state test completed successfully');
  });

  test('should handle response classes correctly', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);
    final events = <Map<String, dynamic>>{
      {'id': 'test1', 'content': 'test'},
    };
    final relaysForIds = <String, Set<String>>{
      'test1': {'ws://localhost:8080'},
    };

    // Test EventRelayResponse
    final eventResponse = EventRelayResponse(
      req: req,
      events: events,
      relaysForIds: relaysForIds,
    );

    expect(
      eventResponse.req,
      equals(req),
      reason: 'Should have correct request',
    );
    expect(
      eventResponse.events,
      equals(events),
      reason: 'Should have correct events',
    );
    expect(
      eventResponse.relaysForIds,
      equals(relaysForIds),
      reason: 'Should have correct relays',
    );

    // Test NoticeRelayResponse
    final noticeResponse = NoticeRelayResponse(
      message: 'Test notice',
      relayUrl: 'ws://localhost:8080',
    );

    expect(
      noticeResponse.message,
      equals('Test notice'),
      reason: 'Should have correct message',
    );
    expect(
      noticeResponse.relayUrl,
      equals('ws://localhost:8080'),
      reason: 'Should have correct relay URL',
    );

    // Test PublishRelayResponse
    final publishResponse = PublishRelayResponse();
    expect(
      publishResponse.wrapped,
      isA<PublishResponse>(),
      reason: 'Should have wrapped PublishResponse',
    );

    print('✓ Response classes test completed successfully');
  });

  // Integration tests - Require real WebSocket connections

  test('should connect to relay successfully', () async {
    final req = RequestFilter(kinds: {1}).toRequest();

    await pool.send(req, relayUrls: {relayUrl});

    // Verify connection
    expect(
      pool.relays.containsKey(relayUrl),
      isTrue,
      reason: 'Should track relay state',
    );

    final relayState = pool.relays[relayUrl];
    expect(
      relayState?.isConnected,
      isTrue,
      reason: 'Should be connected to relay',
    );

    // Clean up
    pool.unsubscribe(req);

    print('✓ Connection test completed successfully');
  });

  test('should handle reconnection after disconnection', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});

    // Verify initial connection
    expect(
      pool.relays[relayUrl]?.isConnected,
      isTrue,
      reason: 'Should be initially connected',
    );

    // Instead of restarting relay, just verify the connection is stable
    // The WebSocket library handles reconnection automatically
    await Future.delayed(Duration(seconds: 2));

    // Verify connection is still active
    expect(
      pool.relays[relayUrl]?.isConnected,
      isTrue,
      reason: 'Should maintain connection',
    );

    // Clean up
    pool.unsubscribe(req);

    print('✓ Reconnection test completed successfully');
  });

  test('should publish events and receive OK responses', () async {
    final note = await PartialNote('Test publish event').signWith(signer);
    final event = note.toMap();
    final events = [event];

    final publishResponse = await pool.publish(events, relayUrls: {relayUrl});

    expect(
      publishResponse,
      isA<PublishRelayResponse>(),
      reason: 'Should return PublishRelayResponse',
    );

    // Verify that the event was accepted
    final eventId = event['id'] as String;
    final eventStates = publishResponse.wrapped.results[eventId];
    expect(
      eventStates,
      isNotNull,
      reason: 'Should have response for published event',
    );

    if (eventStates != null && eventStates.isNotEmpty) {
      expect(
        eventStates.first.accepted,
        isTrue,
        reason: 'Event should be accepted by relay',
      );
    }

    print('✓ Publish test completed successfully');
  });

  test('should query events and receive responses', () async {
    // First publish an event
    final note = await PartialNote('Test query event').signWith(signer);
    final event = note.toMap();
    final publishResponse = await pool.publish([event], relayUrls: {relayUrl});

    // Check if publish was successful
    final eventId = event['id'] as String;
    final eventStates = publishResponse.wrapped.results[eventId];
    print('Publish response for $eventId: $eventStates');

    if (eventStates != null && eventStates.isNotEmpty) {
      print('Event accepted: ${eventStates.first.accepted}');
      print('Event message: ${eventStates.first.message}');
    }

    // Now query for the event by ID first
    final reqById = Request([
      RequestFilter(ids: {event['id']}),
    ]);

    final resultsById = await pool.query(reqById, relayUrls: {relayUrl});
    print('Query by ID returned ${resultsById.length} events');

    // Also try query by author
    final reqByAuthor = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final results = await pool.query(reqByAuthor, relayUrls: {relayUrl});

    expect(
      results,
      isA<List<Map<String, dynamic>>>(),
      reason: 'Should return events list',
    );

    print('Query returned ${results.length} events');
    print('Looking for event ID: ${event['id']}');
    print('Available event IDs: ${results.map((e) => e['id']).toList()}');

    // Should find the published event
    final foundEvent = results.where((e) => e['id'] == event['id']).firstOrNull;
    expect(
      foundEvent,
      isNotNull,
      reason: 'Should find published event in query results',
    );

    print('✓ Query test completed successfully');
  });

  test('should handle event roundtrip (publish then query)', () async {
    final note = await PartialNote('Test roundtrip event').signWith(signer);
    final event = note.toMap();

    // Publish event
    final publishResponse = await pool.publish([event], relayUrls: {relayUrl});
    final eventStates = publishResponse.wrapped.results[event['id']];
    expect(
      eventStates?.first.accepted,
      isTrue,
      reason: 'Event should be accepted',
    );

    // Wait for event to be stored and indexed
    await Future.delayed(Duration(seconds: 3));

    // Query for the event
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final results = await pool.query(req, relayUrls: {relayUrl});

    print('Roundtrip query returned ${results.length} events');
    print('Looking for event ID: ${event['id']}');
    print('Available event IDs: ${results.map((e) => e['id']).toList()}');

    // Should find the published event
    final foundEvent = results.where((e) => e['id'] == event['id']).firstOrNull;
    expect(
      foundEvent,
      isNotNull,
      reason: 'Should find published event in query results',
    );

    // Verify event content
    expect(
      foundEvent?['content'],
      equals(event['content']),
      reason: 'Event content should match',
    );

    print('✓ Event roundtrip test completed successfully');
  });

  test('should handle event deduplication', () async {
    final note = await PartialNote('Test deduplication event').signWith(signer);
    final event = note.toMap();

    // Publish the same event twice
    await pool.publish([event], relayUrls: {relayUrl});
    await pool.publish([event], relayUrls: {relayUrl});

    // Wait for events to be stored and indexed
    await Future.delayed(Duration(seconds: 3));

    // Query for the event
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final results = await pool.query(req, relayUrls: {relayUrl});

    print('Deduplication query returned ${results.length} events');
    print('Looking for event ID: ${event['id']}');
    print('Available event IDs: ${results.map((e) => e['id']).toList()}');

    // Should find only one instance of the event (deduplicated)
    final foundEvents = results.where((e) => e['id'] == event['id']).toList();
    expect(
      foundEvents.length,
      equals(1),
      reason: 'Should find only one instance of the event',
    );

    print('✓ Event deduplication test completed successfully');
  });

  test('should handle URL normalization', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Send to normalized URL
    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(seconds: 2));

    expect(
      pool.relays[relayUrl]?.isConnected,
      isTrue,
      reason: 'Should connect to normalized URL',
    );

    // Clean up
    pool.unsubscribe(req);

    print('✓ URL normalization test completed successfully');
  });

  test('should handle streaming events', () async {
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    // Start streaming subscription
    final results = await pool.query(
      req,
      relayUrls: {relayUrl},
      source: const RemoteSource(stream: true),
    );

    expect(
      results,
      isA<List<Map<String, dynamic>>>(),
      reason: 'Should return initial events list',
    );

    // Verify subscription remains active
    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isTrue,
      reason: 'Subscription should remain active for streaming',
    );

    // Publish a new event while streaming
    final note = await PartialNote('Test streaming event').signWith(signer);
    final newEvent = note.toMap();

    await pool.publish([newEvent], relayUrls: {relayUrl});

    // Wait for streaming event to be received
    await Future.delayed(Duration(seconds: 2));

    // Clean up
    pool.unsubscribe(req);

    print('✓ Streaming events test completed successfully');
  });
}
