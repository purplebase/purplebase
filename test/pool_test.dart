import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'dart:convert';
import 'helpers.dart';
import 'mocks/websocket_server_mock.dart';

void main() {
  late ProviderContainer container;
  late MockWebSocketClient mockClient;
  late WebSocketPool webSocketPool;

  setUp(() {
    mockClient = MockWebSocketClient();

    container = ProviderContainer(
      overrides: [webSocketClientProvider.overrideWithValue(mockClient)],
    );

    final config = StorageConfiguration(
      databasePath: '',
      relayGroups: {},
      defaultRelayGroup: '',
      streamingBufferWindow: Duration.zero,
    );

    webSocketPool = WebSocketPool(container.read(refProvider), config);
  });

  tearDown(() {
    container.dispose();
  });

  group('Connection Management Tests', () {
    test('connects to relays when sending requests', () async {
      // Define relay URLs
      final relayUrls = {'wss://relay1.com', 'wss://relay2.com'};

      // Create a simple request filter
      final filter = RequestFilter(
        kinds: {1}, // Text notes in Nostr
        limit: 10,
      );

      // Send the request to the relays
      await webSocketPool.send(filter, relayUrls: relayUrls);

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
      // Create a filter and send it to a relay
      final relayUrl = 'wss://relay.com';
      final filter = RequestFilter(kinds: {1});

      await webSocketPool.send(filter, relayUrls: {relayUrl});

      // Clear sent messages to start fresh
      mockClient.getSentMessages(relayUrl).clear();

      // Unsubscribe from the subscription
      webSocketPool.unsubscribe(filter.subscriptionId);

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
      final tester = StateNotifierTester(webSocketPool);

      // Create and send a filter to a relay
      final relayUrl = 'wss://relay.com';
      final relay2Url = 'wss://relay2.com';
      final filter = RequestFilter(kinds: {1});

      await webSocketPool.send(filter, relayUrls: {relayUrl, relay2Url});

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

      await tester.expect(
        isA<(List<Map<String, dynamic>>, (String, String))>()
            .having((s) => s.$1, 'models', hasLength(2))
            .having((s) => s.$2.$1, 'relay', 'wss://relay.com'),
      );

      await tester.expect(
        isA<(List<Map<String, dynamic>>, (String, String))>()
            .having((s) => s.$1, 'models', [
              {'id': '1234'},
            ])
            .having((s) => s.$2.$1, 'relay', 'wss://relay2.com'),
      );
    });

    test('handles events pre-EOSE with buffering', () async {
      final tester = StateNotifierTester(webSocketPool);

      // Create and send a filter to a relay
      final relayUrl = 'wss://relay.com';
      final filter = RequestFilter(kinds: {1});

      await webSocketPool.send(filter, relayUrls: {relayUrl});

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

      // Now send EOSE to trigger buffer flush
      mockClient.sendEose(relayUrl, filter.subscriptionId);

      await tester.expect(
        isA<(List<Map<String, dynamic>>, (String, String))>()
            .having((s) => s.$1, 'models', hasLength(2))
            .having(
              (s) => s.$1.any((e) => e['id'] == 'pre-eose1'),
              'any pre-eose1',
              isTrue,
            )
            .having(
              (s) => s.$1.any((e) => e['id'] == 'pre-eose2'),
              'any pre-eose2',
              isTrue,
            ),
      );
    });

    test('handles streaming events after EOSE with buffering', () async {
      final tester = StateNotifierTester(webSocketPool);

      // Create and send a filter to a relay
      final relayUrl = 'wss://relay.com';
      final filter = RequestFilter(kinds: {1});

      await webSocketPool.send(filter, relayUrls: {relayUrl});

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

      // TODO: Verify events aren't immediately in state (buffering)
      // var state = container.read(webSocketPoolProvider.notifier).state;
      // expect(state, isNull);

      // Send another event
      mockClient.sendEvent(relayUrl, filter.subscriptionId, streamEvent2);

      await tester.expect(
        isA<(List<Map<String, dynamic>>, (String, String))>()
            .having(
              (s) => s.$1.any((e) => e['id'] == 'stream1'),
              'any stream1',
              isTrue,
            )
            .having(
              (s) => s.$1.any((e) => e['id'] == 'stream2'),
              'any stream2',
              isTrue,
            ),
      );
    });
  });

  group('Timestamp Optimization Tests', () {
    test('optimizes requests with latest seen timestamps', () async {
      // Create and send a filter to a relay
      final relayUrl = 'wss://relay.com';
      final filter = RequestFilter(kinds: {1});

      await webSocketPool.send(filter, relayUrls: {relayUrl});

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
      await webSocketPool.send(filter, relayUrls: {relayUrl});

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
      final tester = StateNotifierTester(webSocketPool);

      // Create two different filters
      final relayUrl = 'wss://relay.com';
      final filter1 = RequestFilter(kinds: {1}, limit: 5);
      final filter2 = RequestFilter(kinds: {4}, limit: 10);

      // Send both filters
      await webSocketPool.send(filter1, relayUrls: {relayUrl});

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

      // Verify state has filter1's event
      await tester.expect(
        isA<(List<Map>, (String, String))>()
            .having((s) => s.$2.$1, 'relay', 'wss://relay2.com')
            .having(
              (s) => s.$1.any((e) => e['id'] == 'event1'),
              'models',
              isTrue,
            ),
      );

      // Now send filter2
      await webSocketPool.send(filter2, relayUrls: {relayUrl});

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

      // Verify state now has filter2's event
      await tester.expect(
        isA<(List<Map>, (String, String))>()
            .having((s) => s.$2.$1, 'relay', 'wss://relay2.com')
            .having(
              (s) => s.$1.any((e) => e['id'] == 'event2'),
              'models',
              isTrue,
            )
            .having(
              (s) => s.$1.any((e) => e['id'] == 'event1'),
              'models',
              isFalse,
            ),
      );
    });
  });
}
