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
    await signer.signIn();

    // Create test events
    await createTestEvents();

    // Start relay on a random port
    final port = 8080 + (DateTime.now().millisecondsSinceEpoch % 1000);
    relayUrl = 'ws://localhost:$port';

    // Create and start the relay
    relay = NostrRelay(
      port: port,
      host: '127.0.0.1',
      ref: container.read(refProvider),
    );
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
    pool = WebSocketPool(
      config: config,
      eventNotifier: RelayEventNotifier(),
      statusNotifier: PoolStatusNotifier(
        throttleDuration: config.streamingBufferWindow,
      ),
    );
  });

  tearDown(() async {
    pool.dispose();
  });

  // Unit tests for edge cases and state classes
  test('should handle publish with empty events list', () async {
    // Publish empty events list to actual relay
    final source = RemoteSource(relayUrls: {relayUrl});
    final publishResponse = await pool.publish([], source: source);

    expect(
      publishResponse,
      isA<PublishRelayResponse>(),
      reason: 'Should return PublishRelayResponse even with empty events',
    );

    // Verify that no events were sent (since list was empty)
    expect(
      publishResponse.wrapped.results,
      isEmpty,
      reason: 'Should have no results when publishing empty events list',
    );
  });

  test('should handle publish with empty relay URLs', () async {
    final source = RemoteSource(relayUrls: {}, group: 'missing');
    final publishResponse = await pool.publish(testEvents, source: source);

    expect(
      publishResponse,
      isA<PublishRelayResponse>(),
      reason: 'Should return PublishRelayResponse with empty relay URLs',
    );

    // Verify that no results are returned when no relays are specified
    expect(
      publishResponse.wrapped.results,
      isEmpty,
      reason: 'Should have no results when no relay URLs provided',
    );
  });

  test('should handle query with background=true', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    final source = RemoteSource(relayUrls: {relayUrl}, background: true);
    final result = await pool.query(req, source: source);

    // Should return empty list when background=true
    expect(
      result,
      isEmpty,
      reason: 'Should return empty list when background=true',
    );

    // Verify that subscription was created for background query
    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isTrue,
      reason: 'Should create subscription for background query',
    );

    // Clean up
    pool.unsubscribe(req);
  });

  test('should handle query with non-existent subscription', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Query without sending the request first
    // This should return empty list since subscription doesn't exist
    final source = RemoteSource(relayUrls: {relayUrl});
    final result = await pool.query(req, source: source);

    expect(
      result,
      isEmpty,
      reason: 'Should return empty list for non-existent subscription',
    );

    // Verify that subscription was created for this query (since we provided relay URLs)
    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isTrue,
      reason: 'Should create subscription when relay URLs are provided',
    );

    // Clean up
    pool.unsubscribe(req);
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
  });

  test('should handle send with actual relay URLs', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Send with actual relay URLs
    await pool.send(req, relayUrls: {relayUrl});

    // Should create subscription
    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isTrue,
      reason: 'Should create subscription for actual relay URLs',
    );

    // Verify relay connection
    expect(
      pool.relays.containsKey(relayUrl),
      isTrue,
      reason: 'Should track relay state',
    );

    expect(
      pool.relays[relayUrl]?.isConnected,
      isTrue,
      reason: 'Should be connected to relay',
    );

    // Clean up
    pool.unsubscribe(req);
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
  });

  test('should handle reconnection after disconnection', () async {
    // Create a pool with a very short idle timeout to force disconnection
    final shortTimeoutConfig = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {relayUrl},
      },
      defaultRelayGroup: 'test',
      responseTimeout: Duration(seconds: 5),
      streamingBufferWindow: Duration(milliseconds: 100),
      idleTimeout: Duration(milliseconds: 500), // Very short timeout
    );
    final shortTimeoutPool = WebSocketPool(
      config: shortTimeoutConfig,
      eventNotifier: RelayEventNotifier(),
      statusNotifier: PoolStatusNotifier(
        throttleDuration: shortTimeoutConfig.streamingBufferWindow,
      ),
    );

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Establish initial connection
    await shortTimeoutPool.send(req, relayUrls: {relayUrl});

    // Verify initial connection
    expect(
      shortTimeoutPool.relays[relayUrl]?.isConnected,
      isTrue,
      reason: 'Should be initially connected',
    );

    // Unsubscribe to allow idle timeout to trigger
    shortTimeoutPool.unsubscribe(req);

    // Wait for idle timeout to trigger disconnection
    await Future.delayed(Duration(seconds: 1));

    // Verify connection is now disconnected due to idle timeout
    expect(
      shortTimeoutPool.relays[relayUrl]?.isDisconnected,
      isTrue,
      reason: 'Should be disconnected after idle timeout',
    );

    // Test that we can attempt to reconnect by sending a new request
    final newReq = Request([
      RequestFilter(kinds: {1}),
    ]);

    await shortTimeoutPool.send(newReq, relayUrls: {relayUrl});

    // Wait for reconnection
    bool isReconnected = false;
    for (int i = 0; i < 30; i++) {
      // Try for up to 3 seconds
      await Future.delayed(Duration(milliseconds: 100));
      if (shortTimeoutPool.relays[relayUrl]?.isConnected == true) {
        isReconnected = true;
        break;
      }
    }

    expect(
      isReconnected,
      isTrue,
      reason: 'Should be reconnected after sending new request',
    );

    // Test that we can still communicate after reconnection
    final note = await PartialNote('Test reconnection event').signWith(signer);
    final event = note.toMap();

    final source = RemoteSource(relayUrls: {relayUrl});
    final publishResponse = await shortTimeoutPool.publish([
      event,
    ], source: source);

    // Verify the event was accepted
    final eventId = event['id'] as String;
    final eventStates = publishResponse.wrapped.results[eventId];
    expect(
      eventStates?.first.accepted,
      isTrue,
      reason: 'Should be able to publish after reconnection',
    );

    // Clean up
    shortTimeoutPool.unsubscribe(req);
    shortTimeoutPool.unsubscribe(newReq);
    shortTimeoutPool.dispose();
  });

  test('should publish events and receive OK responses', () async {
    final note = await PartialNote('Test publish event').signWith(signer);
    final event = note.toMap();
    final events = [event];

    final source = RemoteSource(relayUrls: {relayUrl});
    final publishResponse = await pool.publish(events, source: source);

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
  });

  test('should query events and receive responses', () async {
    // First publish an event
    final note = await PartialNote('Test query event').signWith(signer);
    final event = note.toMap();
    final publishResponse = await pool.publish([
      event,
    ], source: RemoteSource(relayUrls: {relayUrl}));

    // Check if publish was successful
    final eventId = event['id'] as String;
    final eventStates = publishResponse.wrapped.results[eventId];

    if (eventStates != null && eventStates.isNotEmpty) {
      // Event was accepted
    }

    // Now query for the event by ID first
    final reqById = Request([
      RequestFilter(ids: {event['id']}),
    ]);

    await pool.query(reqById, source: RemoteSource(relayUrls: {relayUrl}));

    // Also try query by author
    final reqByAuthor = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final results = await pool.query(
      reqByAuthor,
      source: RemoteSource(relayUrls: {relayUrl}),
    );

    expect(
      results,
      isA<List<Map<String, dynamic>>>(),
      reason: 'Should return events list',
    );

    // Should find the published event
    final foundEvent = results.where((e) => e['id'] == event['id']).firstOrNull;
    expect(
      foundEvent,
      isNotNull,
      reason: 'Should find published event in query results',
    );
  });

  test('should handle event roundtrip (publish then query)', () async {
    final note = await PartialNote('Test roundtrip event').signWith(signer);
    final event = note.toMap();

    // Publish event
    final publishResponse = await pool.publish([
      event,
    ], source: RemoteSource(relayUrls: {relayUrl}));
    final eventStates = publishResponse.wrapped.results[event['id']];
    expect(
      eventStates?.first.accepted,
      isTrue,
      reason: 'Event should be accepted',
    );

    // Query for the event
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final results = await pool.query(
      req,
      source: RemoteSource(relayUrls: {relayUrl}),
    );

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
  });

  test('should handle event deduplication', () async {
    final note = await PartialNote('Test deduplication event').signWith(signer);
    final event = note.toMap();

    // Publish the same event twice
    final source = RemoteSource(relayUrls: {relayUrl});
    await pool.publish([event], source: source);
    await pool.publish([event], source: source);

    // Query for the event
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    final results = await pool.query(
      req,
      source: RemoteSource(relayUrls: {relayUrl}),
    );

    // Should find only one instance of the event (deduplicated)
    final foundEvents = results.where((e) => e['id'] == event['id']).toList();
    expect(
      foundEvents.length,
      equals(1),
      reason: 'Should find only one instance of the event',
    );
  });

  test('should handle URL normalization', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Test various URL variations that should all normalize to the same relay
    final urlVariations = [
      relayUrl, // Base URL
      '$relayUrl/', // With trailing slash
      '$relayUrl//', // With double trailing slash
      relayUrl.toUpperCase(), // Uppercase (if it has letters)
    ];

    // Send to first variation
    await pool.send(req, relayUrls: {urlVariations[0]});

    // Wait for connection
    await Future.delayed(Duration(milliseconds: 100));

    // Verify connection exists with normalized URL
    final normalizedUrl = relayUrl.toLowerCase();
    expect(
      pool.relays[normalizedUrl]?.isConnected,
      isTrue,
      reason: 'Should connect to normalized URL',
    );

    // Verify all variations point to the same relay (should only create one connection)
    expect(
      pool.relays.length,
      equals(1),
      reason: 'Should only have one relay connection despite URL variations',
    );

    // Send another request with a different URL variation (with trailing slash)
    final req2 = Request([
      RequestFilter(kinds: {2}),
    ]);
    await pool.send(req2, relayUrls: {'$relayUrl/'});

    // Wait a bit
    await Future.delayed(Duration(milliseconds: 100));

    // Should still only have one relay connection
    expect(
      pool.relays.length,
      equals(1),
      reason: 'URLs with trailing slashes should normalize to same relay',
    );

    // Clean up
    pool.unsubscribe(req);
    pool.unsubscribe(req2);
  });

  test('should handle streaming events', () async {
    final req = Request([
      RequestFilter(kinds: {1}, authors: {signer.pubkey}),
    ]);

    // Start streaming subscription
    final results = await pool.query(req, source: RemoteSource(stream: true));

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

    await pool.publish([newEvent], source: RemoteSource(relayUrls: {relayUrl}));

    // Clean up
    pool.unsubscribe(req);
  });

  test(
    'should optimize request filters based on latest seen timestamps',
    () async {
      // Create initial request without since filter
      final initialReq = Request([
        RequestFilter(kinds: {1}, authors: {signer.pubkey}),
      ]);

      // Send initial request and simulate receiving an event
      await pool.send(initialReq, relayUrls: {relayUrl});

      // Simulate receiving an event with timestamp
      final eventTimestamp = DateTime.now();
      final testEvent = {
        'id': 'test_event_id',
        'kind': 1,
        'pubkey': signer.pubkey,
        'created_at': eventTimestamp.toSeconds(),
        'content': 'Test event for timestamp optimization',
        'tags': [],
        'sig': 'test_signature',
      };

      // Manually trigger event handling to store timestamp
      pool.handleEvent(relayUrl, [
        'EVENT',
        initialReq.subscriptionId,
        testEvent,
      ]);

      // Create a new request with the same filters
      final newReq = Request([
        RequestFilter(kinds: {1}, authors: {signer.pubkey}),
      ]);

      // Send the new request - it should be optimized with the stored timestamp
      await pool.send(newReq, relayUrls: {relayUrl});

      // Verify that the timestamp was stored
      final storedTimestamp = pool.getRelayRequestTimestamp(
        relayUrl,
        initialReq,
      );
      expect(
        storedTimestamp,
        isNotNull,
        reason: 'Should store the event timestamp for relay-request pair',
      );
      expect(
        storedTimestamp!.millisecondsSinceEpoch ~/ 1000,
        equals(eventTimestamp.toSeconds()),
        reason:
            'Should store the correct event timestamp for relay-request pair',
      );

      // Clean up
      pool.unsubscribe(initialReq);
      pool.unsubscribe(newReq);
    },
  );

  test(
    'should respect existing since filter when it is newer than stored timestamp',
    () async {
      // Create initial request without since filter
      final initialReq = Request([
        RequestFilter(kinds: {1}, authors: {signer.pubkey}),
      ]);

      // Send initial request and simulate receiving an event
      await pool.send(initialReq, relayUrls: {relayUrl});

      // Simulate receiving an event with old timestamp
      final oldTimestamp = DateTime.now().subtract(Duration(hours: 1));
      final testEvent = {
        'id': 'test_event_id',
        'kind': 1,
        'pubkey': signer.pubkey,
        'created_at': oldTimestamp.toSeconds(),
        'content': 'Test event with old timestamp',
        'tags': [],
        'sig': 'test_signature',
      };

      // Manually trigger event handling to store timestamp
      pool.handleEvent(relayUrl, [
        'EVENT',
        initialReq.subscriptionId,
        testEvent,
      ]);

      // Create a new request with a newer since filter
      final newerSince = DateTime.now().subtract(Duration(minutes: 30));
      final newReq = Request([
        RequestFilter(kinds: {1}, authors: {signer.pubkey}, since: newerSince),
      ]);

      // Optimize the request
      final optimizedReq = pool.optimizeRequestForRelay(relayUrl, newReq);

      // Verify that the newer since filter is preserved
      expect(
        optimizedReq.filters.first.since,
        equals(newerSince),
        reason: 'Should preserve newer since filter over stored timestamp',
      );

      // Clean up
      pool.unsubscribe(initialReq);
    },
  );

  test(
    'should use stored timestamp when since filter is older or null',
    () async {
      // Create initial request without since filter
      final initialReq = Request([
        RequestFilter(kinds: {1}, authors: {signer.pubkey}),
      ]);

      // Send initial request and simulate receiving an event
      await pool.send(initialReq, relayUrls: {relayUrl});

      // Simulate receiving an event with recent timestamp
      final recentTimestamp = DateTime.now().subtract(Duration(minutes: 5));
      final testEvent = {
        'id': 'test_event_id',
        'kind': 1,
        'pubkey': signer.pubkey,
        'created_at': recentTimestamp.toSeconds(),
        'content': 'Test event with recent timestamp',
        'tags': [],
        'sig': 'test_signature',
      };

      // Manually trigger event handling to store timestamp
      pool.handleEvent(relayUrl, [
        'EVENT',
        initialReq.subscriptionId,
        testEvent,
      ]);

      // Create a new request with an older since filter
      final olderSince = DateTime.now().subtract(Duration(hours: 2));
      final newReq = Request([
        RequestFilter(kinds: {1}, authors: {signer.pubkey}, since: olderSince),
      ]);

      // Optimize the request
      final optimizedReq = pool.optimizeRequestForRelay(relayUrl, newReq);

      // Verify that the stored timestamp is used instead of the older since filter
      expect(
        optimizedReq.filters.first.since,
        isNotNull,
        reason: 'Should have a since filter',
      );
      expect(
        optimizedReq.filters.first.since!.millisecondsSinceEpoch ~/ 1000,
        equals(recentTimestamp.toSeconds()),
        reason: 'Should use stored timestamp when since filter is older',
      );

      // Clean up
      pool.unsubscribe(initialReq);
    },
  );
}
