import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'dart:convert';
import 'mocks/websocket_server_mock.dart';

void main() {
  late ProviderContainer container;
  late MockWebSocketClient mockClient;

  setUp(() {
    mockClient = MockWebSocketClient();

    container = ProviderContainer(
      overrides: [
        webSocketClientProvider.overrideWithValue(mockClient),
        purplebaseConfigurationProvider.overrideWithValue(
          PurplebaseConfiguration(streamingBufferWindow: Duration.zero),
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  group('Connection Management Tests', () {
    test('connects to relays when sending requests', () async {
      final websocketPool = container.read(websocketPoolProvider.notifier);

      // Define relay URLs
      final relayUrls = {'wss://relay1.com', 'wss://relay2.com'};

      // Create a simple request filter
      final filter = RequestFilter(
        kinds: {1}, // Text notes in Nostr
        limit: 10,
      );

      // Send the request to the relays
      await websocketPool.send(filter, relayUrls: relayUrls);

      // Verify connection attempts to the relays
      expect(mockClient.isConnected, true);

      // Verify a REQ message was sent containing our filter parameters
      for (final url in relayUrls) {
        final messages = mockClient.getSentMessages(url);
        expect(messages.isNotEmpty, true);

        final message = messages.first;
        final [type, subId, request] = jsonDecode(message);
        expect(type, 'REQ');
        expect(subId, filter.subscriptionId);
        expect(request['kinds'], [1]);
        expect(request['limit'], 10);
      }
    });

    test('sends CLOSE messages when unsubscribing', () async {
      final websocketPool = container.read(websocketPoolProvider.notifier);

      // Create a filter and send it to a relay
      final relayUrl = 'wss://relay.com';
      final filter = RequestFilter(kinds: {1});

      await websocketPool.send(filter, relayUrls: {relayUrl});

      // Clear sent messages to start fresh
      mockClient.getSentMessages(relayUrl).clear();

      // Unsubscribe from the subscription
      websocketPool.unsubscribe(filter.subscriptionId);

      // Verify a CLOSE message was sent
      final messages = mockClient.getSentMessages(relayUrl);
      expect(messages.isNotEmpty, true);

      final message = messages.first;
      final parsed = jsonDecode(message);
      expect(parsed[0], 'CLOSE');
      expect(parsed[1], filter.subscriptionId);
    });
  });

  group('Event Handling Tests', () {
    test('properly handles and deduplicates events', () async {
      final websocketPool = container.read(websocketPoolProvider.notifier);

      // Create and send a filter to a relay
      final relayUrl = 'wss://relay.com';
      final relay2Url = 'wss://relay2.com';
      final filter = RequestFilter(kinds: {1});

      await websocketPool.send(filter, relayUrls: {relayUrl, relay2Url});

      // Create test events
      final event1 = {
        'id': '1234',
        'pubkey': 'abc123',
        'created_at': 1677721600, // 2023-03-02
        'kind': 1,
        'content': 'Hello Nostr!',
        'tags': [],
        'sig': 'signature1',
      };

      final event2 = {
        'id': '5678',
        'pubkey': 'def456',
        'created_at': 1677808000, // 2023-03-03
        'kind': 1,
        'content': 'Another message',
        'tags': [],
        'sig': 'signature2',
      };

      // Send events
      mockClient.sendEvent(relayUrl, filter.subscriptionId, event1);
      mockClient.sendEvent(relayUrl, filter.subscriptionId, event2);

      // Send a duplicate event (should be deduplicated)
      mockClient.sendEvent(relay2Url, filter.subscriptionId, event1);

      // Send EOSE to trigger state update
      mockClient.sendEose(relayUrl, filter.subscriptionId);
      mockClient.sendEose(relay2Url, filter.subscriptionId);

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify state
      final state = container.read(websocketPoolProvider.notifier).state;
      expect(state, isNotNull);
      expect(state!.$1.subscriptionId, filter.subscriptionId);
      expect(state.$2.length, 2); // Only 2 events, not 3 (due to deduplication)

      // Verify event content
      expect(state.$2.map((e) => e['id']).toSet(), {'1234', '5678'});
    });

    test('handles events pre-EOSE with buffering', () async {
      final websocketPool = container.read(websocketPoolProvider.notifier);

      // Create and send a filter to a relay
      final relayUrl = 'wss://relay.com';
      final filter = RequestFilter(kinds: {1});

      await websocketPool.send(filter, relayUrls: {relayUrl});

      // Create test events to be received before EOSE
      final event1 = {
        'id': 'pre-eose1',
        'pubkey': 'user1',
        'created_at': 1677894400,
        'kind': 1,
        'content': 'Pre-EOSE message 1',
        'tags': [],
        'sig': 'sig1',
      };

      final event2 = {
        'id': 'pre-eose2',
        'pubkey': 'user2',
        'created_at': 1677894500,
        'kind': 1,
        'content': 'Pre-EOSE message 2',
        'tags': [],
        'sig': 'sig2',
      };

      // Send events before EOSE
      mockClient.sendEvent(relayUrl, filter.subscriptionId, event1);
      mockClient.sendEvent(relayUrl, filter.subscriptionId, event2);

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify events aren't in state yet (they should be buffered)
      var state = container.read(websocketPoolProvider.notifier).state;
      expect(state, isNotNull);
      expect(state!.$2.isEmpty, true);

      // Now send EOSE to trigger buffer flush
      mockClient.sendEose(relayUrl, filter.subscriptionId);

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify all buffered events are now in state
      state = container.read(websocketPoolProvider.notifier).state!;
      expect(state.$2.length, 2);
      expect(state.$2.any((e) => e['id'] == 'pre-eose1'), true);
      expect(state.$2.any((e) => e['id'] == 'pre-eose2'), true);
    });

    test('handles streaming events after EOSE with buffering', () async {
      // Override streaming buffer window for testing
      final websocketPool = container.read(websocketPoolProvider.notifier);

      // Create and send a filter to a relay
      final relayUrl = 'wss://relay.com';
      final filter = RequestFilter(kinds: {1});

      await websocketPool.send(filter, relayUrls: {relayUrl});

      // Send EOSE first to transition to streaming mode
      mockClient.sendEose(relayUrl, filter.subscriptionId);

      // Send streaming events
      final streamEvent1 = {
        'id': 'stream1',
        'pubkey': 'user1',
        'created_at': 1677894400,
        'kind': 1,
        'content': 'Streaming message 1',
        'tags': [],
        'sig': 'sig1',
      };

      final streamEvent2 = {
        'id': 'stream2',
        'pubkey': 'user2',
        'created_at': 1677894500,
        'kind': 1,
        'content': 'Streaming message 2',
        'tags': [],
        'sig': 'sig2',
      };

      // Send events with a small delay between them
      mockClient.sendEvent(relayUrl, filter.subscriptionId, streamEvent1);

      // Verify events aren't immediately in state (buffering)
      var state = container.read(websocketPoolProvider.notifier).state;
      expect(state!.$2.any((e) => e['id'] == 'stream1'), false);

      // Send another event
      mockClient.sendEvent(relayUrl, filter.subscriptionId, streamEvent2);

      // Wait for buffer to flush
      await Future.delayed(const Duration(milliseconds: 150));

      // Verify all streaming events are now in state
      state = container.read(websocketPoolProvider.notifier).state!;
      expect(state.$2.any((e) => e['id'] == 'stream1'), true);
      expect(state.$2.any((e) => e['id'] == 'stream2'), true);
    });
  });

  group('Timestamp Optimization Tests', () {
    test('optimizes requests with latest seen timestamps', () async {
      final websocketPool = container.read(websocketPoolProvider.notifier);

      // Create and send a filter to a relay
      final relayUrl = 'wss://relay.com';
      final filter = RequestFilter(kinds: {1});

      await websocketPool.send(filter, relayUrls: {relayUrl});

      // Create an event with a timestamp
      final event = {
        'id': 'timestamp1',
        'pubkey': 'time123',
        'created_at': 1677894400, // 2023-03-04
        'kind': 1,
        'content': 'Event with timestamp',
        'tags': [],
        'sig': 'signature',
      };

      // Send event and EOSE
      mockClient.sendEvent(relayUrl, filter.subscriptionId, event);
      mockClient.sendEose(relayUrl, filter.subscriptionId);

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Clear sent messages
      mockClient.getSentMessages(relayUrl).clear();

      // Send another request with the same filter
      await websocketPool.send(filter, relayUrls: {relayUrl});

      // Verify the optimized request includes the since parameter
      final messages = mockClient.getSentMessages(relayUrl);
      expect(messages.isNotEmpty, true);

      final message = messages.first;
      final [type, _, request] = jsonDecode(message);
      expect(type, 'REQ');

      // Since should be at or after our event timestamp
      expect(request.containsKey('since'), true);
      expect(request['since'] >= 1677894400, true);
    });
  });

  group('Multiple Subscriptions Tests', () {
    test('handles multiple concurrent subscriptions', () async {
      final websocketPool = container.read(websocketPoolProvider.notifier);

      // Create two different filters
      final relayUrl = 'wss://relay.com';
      final filter1 = RequestFilter(kinds: {1}, limit: 5);
      final filter2 = RequestFilter(kinds: {4}, limit: 10);

      // Send both filters
      await websocketPool.send(filter1, relayUrls: {relayUrl});

      // Create and send an event for filter1
      final event1 = {
        'id': 'event1',
        'pubkey': 'user1',
        'created_at': 1677894400,
        'kind': 1,
        'content': 'For filter 1',
        'tags': [],
        'sig': 'sig1',
      };

      mockClient.sendEvent(relayUrl, filter1.subscriptionId, event1);
      mockClient.sendEose(relayUrl, filter1.subscriptionId);

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify state has filter1's event
      var state = container.read(websocketPoolProvider.notifier).state;
      expect(state!.$1.subscriptionId, filter1.subscriptionId);
      expect(state.$2.any((e) => e['id'] == 'event1'), true);

      // Now send filter2
      await websocketPool.send(filter2, relayUrls: {relayUrl});

      // Create and send an event for filter2
      final event2 = {
        'id': 'event2',
        'pubkey': 'user2',
        'created_at': 1677894500,
        'kind': 4,
        'content': 'For filter 2',
        'tags': [],
        'sig': 'sig2',
      };

      mockClient.sendEvent(relayUrl, filter2.subscriptionId, event2);
      mockClient.sendEose(relayUrl, filter2.subscriptionId);

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify state now has filter2's event
      state = container.read(websocketPoolProvider.notifier).state;
      expect(state!.$1.subscriptionId, filter2.subscriptionId);
      expect(state.$2.any((e) => e['id'] == 'event2'), true);

      // But not filter1's event (since we switched subscriptions)
      expect(state.$2.any((e) => e['id'] == 'event1'), false);
    });
  });
}
