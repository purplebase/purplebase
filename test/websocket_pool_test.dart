import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/src/websocket_pool.dart';
import 'package:test/test.dart';

void main() {
  late List<Process> relayProcesses;
  late List<int> relayPorts;
  late WebSocketPool pool;
  late String testSecKey;
  late String testPubKey;
  late List<Map<String, dynamic>> testEvents;

  Future<void> populateRelayWithTestEvents(int port) async {
    final relayUrl = 'ws://localhost:$port';

    // Create and publish several test events using nak event
    for (int i = 1; i <= 3; i++) {
      final content = 'Test event content $i';
      final eventResult = await Process.run('nak', [
        'event',
        '--sec',
        testSecKey,
        '--content',
        content,
        '--kind',
        '1',
        relayUrl,
      ]);

      if (eventResult.exitCode == 0) {
        // Parse the generated event from output
        final eventJson = eventResult.stdout.toString().trim();
        try {
          final event = jsonDecode(eventJson) as Map<String, dynamic>;
          testEvents.add(event);
          print('Published test event $i: ${event['id']}');
        } catch (e) {
          print('Could not parse event JSON: $eventJson');
        }
      } else {
        print('Failed to publish test event $i: ${eventResult.stderr}');
      }

      // Small delay between events
      await Future.delayed(Duration(milliseconds: 200));
    }

    print('Populated relay with ${testEvents.length} test events');
  }

  setUpAll(() async {
    relayProcesses = [];
    relayPorts = [];
    testEvents = [];

    // Generate a test private key for consistent event creation
    final keyGenResult = await Process.run('nak', ['key', 'generate']);
    if (keyGenResult.exitCode != 0) {
      throw Exception('Failed to generate test key: ${keyGenResult.stderr}');
    }
    testSecKey = keyGenResult.stdout.toString().trim();

    // Get the corresponding public key
    final pubKeyProcess = await Process.start('nak', ['key', 'public']);
    pubKeyProcess.stdin.writeln(testSecKey);
    await pubKeyProcess.stdin.close();
    final pubKeyExitCode = await pubKeyProcess.exitCode;
    if (pubKeyExitCode != 0) {
      throw Exception('Failed to get public key');
    }
    testPubKey = await pubKeyProcess.stdout.transform(utf8.decoder).join();
    testPubKey = testPubKey.trim();

    print('Test keys generated - pubkey: $testPubKey');

    // Create a single relay for testing
    final port = 49152 + (DateTime.now().millisecondsSinceEpoch % 1000);
    relayPorts.add(port);

    // Start nak serve process
    try {
      final process = await Process.start('nak', [
        'serve',
        '--port',
        port.toString(),
      ], mode: ProcessStartMode.detached);
      relayProcesses.add(process);

      // Give relay time to start up
      await Future.delayed(Duration(milliseconds: 3000));

      print('Started nak serve on port $port');

      // Populate relay with test events
      await populateRelayWithTestEvents(port);
    } catch (e) {
      throw Exception(
        'Failed to start nak serve: $e. Make sure nak is installed and available in PATH.',
      );
    }
  });

  tearDownAll(() async {
    // Stop all relay processes
    for (final process in relayProcesses) {
      process.kill();
    }
    relayProcesses.clear();
    relayPorts.clear();
  });

  setUp(() {
    final config = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {'wss://test.com'},
      },
      defaultRelayGroup: 'test',
      responseTimeout: Duration(milliseconds: 500),
    );
    pool = WebSocketPool(config);
  });

  tearDown(() async {
    // Wait a moment for any pending timers to complete
    await Future.delayed(Duration(milliseconds: 100));
    pool.dispose();
  });

  test(
    'should connect to relay and receive events with proper structure',
    () async {
      final expectedRelayUrl = 'ws://localhost:${relayPorts[0]}';
      final relayUrls = {expectedRelayUrl};

      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      final responsesFuture =
          pool.stream
              .where(
                (response) =>
                    response != null && response is EventRelayResponse,
              )
              .first;

      await pool.send(req, relayUrls: relayUrls);

      final response = await responsesFuture.timeout(Duration(seconds: 8));

      // Verify response structure
      expect(response, isNotNull, reason: 'Response should not be null');
      expect(
        response,
        isA<EventRelayResponse>(),
        reason: 'Should be EventRelayResponse',
      );

      final eventResponse = response as EventRelayResponse;

      // Verify response structure
      expect(
        eventResponse.req,
        equals(req),
        reason: 'Event response should reference the original request',
      );
      expect(
        eventResponse.events.isNotEmpty,
        isTrue,
        reason: 'Event response should have events',
      );

      // Extract all events from the response
      final allEvents = eventResponse.events.toList();

      expect(
        allEvents.isNotEmpty,
        isTrue,
        reason: 'Event response should contain events',
      );

      // Verify event structure - check first event as example
      final event = allEvents.first;
      expect(
        event.containsKey('id'),
        isTrue,
        reason: 'Event should have id field',
      );
      expect(event['id'], isA<String>(), reason: 'Event id should be string');
      expect(
        event['id'].toString().length,
        equals(64),
        reason: 'Event id should be 64 char hex',
      );

      expect(
        event.containsKey('pubkey'),
        isTrue,
        reason: 'Event should have pubkey field',
      );
      expect(
        event['pubkey'],
        equals(testPubKey),
        reason: 'Event should have our test pubkey',
      );

      expect(
        event.containsKey('kind'),
        isTrue,
        reason: 'Event should have kind field',
      );
      expect(
        event['kind'],
        equals(1),
        reason: 'Event should be kind 1 (text note)',
      );

      expect(
        event.containsKey('content'),
        isTrue,
        reason: 'Event should have content field',
      );
      expect(
        event['content'],
        isA<String>(),
        reason: 'Event content should be string',
      );

      print(
        '✓ Received properly structured event response with ${allEvents.length} events',
      );
    },
  );

  test('should handle query method and return events', () async {
    final expectedRelayUrl = 'ws://localhost:${relayPorts[0]}';
    final relayUrls = {expectedRelayUrl};
    final limit = 5;

    final req = Request([
      RequestFilter(kinds: {1}, limit: limit),
    ]);

    final result = await pool.query(req, relayUrls: relayUrls);

    // Comprehensive validation of query results
    expect(
      result,
      isA<List<Map<String, dynamic>>>(),
      reason: 'Query result should be List<Map<String, dynamic>>',
    );
    expect(
      result.length,
      greaterThan(0),
      reason: 'Should return at least one event',
    );
    expect(
      result.length,
      lessThanOrEqualTo(limit),
      reason: 'Should not exceed requested limit',
    );

    // Validate each returned event
    final eventIds = <String>{};
    for (final event in result) {
      expect(
        event,
        isA<Map<String, dynamic>>(),
        reason: 'Each result should be a valid event',
      );
      expect(
        event.containsKey('id'),
        isTrue,
        reason: 'Each event should have an ID',
      );

      final eventId = event['id'] as String;
      expect(
        eventIds.contains(eventId),
        isFalse,
        reason: 'Should not have duplicate events in query result',
      );
      eventIds.add(eventId);

      expect(
        event['kind'],
        equals(1),
        reason: 'Event should be kind 1 (matches filter)',
      );
      expect(
        event['pubkey'],
        equals(testPubKey),
        reason: 'Event should have our test pubkey',
      );
    }

    print('✓ Query returned ${result.length} unique, valid events');
  });

  test('should handle buffering behavior correctly', () async {
    final expectedRelayUrl = 'ws://localhost:${relayPorts[0]}';
    final relayUrls = {expectedRelayUrl};

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    final responsesFuture =
        pool.stream
            .where(
              (response) => response != null && response is EventRelayResponse,
            )
            .first;

    await pool.send(req, relayUrls: relayUrls);

    final response = await responsesFuture.timeout(Duration(seconds: 8));

    expect(response, isNotNull, reason: 'Buffered response should not be null');
    expect(
      response,
      isA<EventRelayResponse>(),
      reason: 'Buffered response should be EventRelayResponse',
    );

    final eventResponse = response as EventRelayResponse;
    expect(
      eventResponse.events.isNotEmpty,
      isTrue,
      reason: 'Should receive buffered events',
    );

    // Verify the response has the same req (they were buffered from same subscription)
    expect(
      eventResponse.req.subscriptionId,
      equals(req.subscriptionId),
      reason: 'Buffered events should have same subscription ID',
    );

    // Verify events are properly structured and not duplicated
    final eventIds =
        eventResponse.events.map((event) => event['id'] as String).toList();
    expect(
      eventIds.toSet().length,
      equals(eventIds.length),
      reason: 'Buffered events should not contain duplicates',
    );

    print(
      '✓ Buffered ${eventResponse.events.length} events with proper structure',
    );
  });

  test('should handle connection management correctly', () async {
    final expectedRelayUrl = 'ws://localhost:${relayPorts[0]}';
    final relayUrls = {expectedRelayUrl};

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    // Verify initial state
    expect(
      pool.relays,
      isEmpty,
      reason: 'Should start with no relay connections',
    );
    expect(
      pool.subscriptions,
      isEmpty,
      reason: 'Should start with no subscriptions',
    );

    await pool.send(req, relayUrls: relayUrls);

    // Give time for connection to establish
    await Future.delayed(Duration(milliseconds: 1500));

    // Verify connection state
    expect(
      pool.relays.containsKey(expectedRelayUrl),
      isTrue,
      reason: 'Should track the relay connection',
    );

    final relayState = pool.relays[expectedRelayUrl];
    expect(relayState, isNotNull, reason: 'Relay state should exist');
    expect(
      relayState!.isConnected,
      isTrue,
      reason: 'Relay should be connected',
    );

    // Verify subscription state
    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isTrue,
      reason: 'Should track the subscription',
    );

    final subscriptionState = pool.subscriptions[req.subscriptionId];
    expect(
      subscriptionState,
      isNotNull,
      reason: 'Subscription state should exist',
    );
    expect(
      subscriptionState!.req.subscriptionId,
      equals(req.subscriptionId),
      reason: 'Subscription should have correct ID',
    );
    expect(
      subscriptionState.targetRelays,
      equals(relayUrls),
      reason: 'Subscription should target correct relays',
    );

    print('✓ Connection management verified - relay connected and tracked');
  });

  test('should handle unsubscribe correctly', () async {
    final expectedRelayUrl = 'ws://localhost:${relayPorts[0]}';
    final relayUrls = {expectedRelayUrl};

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: relayUrls);

    // Give time for subscription to establish
    await Future.delayed(Duration(milliseconds: 1500));

    // Verify subscription exists
    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isTrue,
      reason: 'Subscription should exist before unsubscribe',
    );

    final subscriptionCountBefore = pool.subscriptions.length;

    pool.unsubscribe(req);

    // Verify subscription cleanup
    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isFalse,
      reason: 'Subscription should be removed after unsubscribe',
    );
    expect(
      pool.subscriptions.length,
      equals(subscriptionCountBefore - 1),
      reason: 'Subscription count should decrease by 1',
    );

    print('✓ Unsubscribe completed with proper cleanup');
  });

  test('should deduplicate events correctly', () async {
    final expectedRelayUrl = 'ws://localhost:${relayPorts[0]}';
    final relayUrls = {expectedRelayUrl};

    // First, let's test a single request to make sure we get all events
    final singleReq = Request([
      RequestFilter(kinds: {1}),
    ]);

    final singleResult = await pool.query(singleReq, relayUrls: relayUrls);

    print('Single request returned ${singleResult.length} events');
    expect(
      singleResult.length,
      equals(3),
      reason: 'Single request should return all 3 published events',
    );

    // Now test deduplication with two separate requests sent sequentially
    final req1 = Request([
      RequestFilter(kinds: {1}, limit: 5),
    ]);

    final req2 = Request([
      RequestFilter(kinds: {1}, limit: 3),
    ]);

    // Send requests sequentially and collect results
    final result1 = await pool.query(req1, relayUrls: relayUrls);
    final result2 = await pool.query(req2, relayUrls: relayUrls);

    print('Request 1 returned ${result1.length} events');
    print('Request 2 returned ${result2.length} events');

    // Both requests should return all available events (up to their limits)
    expect(
      result1.length,
      equals(3),
      reason: 'Request 1 should return all 3 events (within limit of 5)',
    );
    expect(
      result2.length,
      equals(3),
      reason: 'Request 2 should return all 3 events (within limit of 3)',
    );

    // Collect all events for deduplication analysis
    final allEvents = <Map<String, dynamic>>[];
    allEvents.addAll(result1);
    allEvents.addAll(result2);

    expect(
      allEvents.isNotEmpty,
      isTrue,
      reason: 'Should have received events from both requests',
    );

    // Extract event IDs to check for duplicates
    final eventIds = allEvents.map((event) => event['id'] as String).toList();
    final uniqueEventIds = eventIds.toSet();

    // Since both requests overlap (both asking for kind 1 events),
    // we expect all events to appear in both results (6 total, 3 unique)
    expect(
      eventIds.length,
      equals(6),
      reason: 'Should have 6 total events (3 events × 2 requests)',
    );
    expect(
      uniqueEventIds.length,
      equals(3),
      reason: 'Should have 3 unique events',
    );
    expect(
      eventIds.length,
      greaterThan(uniqueEventIds.length),
      reason: 'Should have duplicate events across the two requests',
    );

    // Verify that within each individual result, events are not duplicated
    final result1EventIds = result1.map((e) => e['id'] as String).toList();
    final uniqueResult1EventIds = result1EventIds.toSet();

    final result2EventIds = result2.map((e) => e['id'] as String).toList();
    final uniqueResult2EventIds = result2EventIds.toSet();

    expect(
      result1EventIds.length,
      equals(uniqueResult1EventIds.length),
      reason: 'Events within result1 should be deduplicated',
    );
    expect(
      result2EventIds.length,
      equals(uniqueResult2EventIds.length),
      reason: 'Events within result2 should be deduplicated',
    );

    // Additional verification: ensure events have proper structure
    for (final event in allEvents) {
      expect(
        event.containsKey('id'),
        isTrue,
        reason: 'Each event should have an ID',
      );
      expect(event['id'], isA<String>(), reason: 'Event ID should be a string');
      expect(
        (event['id'] as String).length,
        equals(64),
        reason: 'Event ID should be 64 characters (hex)',
      );
    }

    print(
      '✓ Deduplication verified: ${eventIds.length} total events, '
      '${uniqueEventIds.length} unique events across 2 requests',
    );
  });

  test('should normalize URLs correctly', () async {
    final port = relayPorts[0];
    final urlWithSlash = 'ws://localhost:$port/';
    final urlWithoutSlash = 'ws://localhost:$port';
    final relayUrls = {urlWithSlash, urlWithoutSlash};

    expect(
      relayUrls.length,
      equals(2),
      reason: 'Should start with 2 different URL formats',
    );

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: relayUrls);

    // Give time for connection normalization
    await Future.delayed(Duration(milliseconds: 1000));

    // Verify URL normalization - should only have one connection
    final connectedRelays =
        pool.relays.keys
            .map(Uri.parse)
            .where((uri) => uri.host == 'localhost' && uri.port == port)
            .toList();

    expect(
      connectedRelays.length,
      equals(1),
      reason: 'Should normalize to exactly one URL',
    );

    final normalizedUrl = connectedRelays.first;
    expect(
      normalizedUrl.toString(),
      equals('ws://localhost:$port'),
      reason: 'Normalized URL should not have trailing slash',
    );

    print('✓ URL normalization successful: $normalizedUrl');
  });

  test('should reconnect and resend subscriptions after relay restart', () async {
    final port = relayPorts[0];
    final expectedRelayUrl = 'ws://localhost:$port';
    final relayUrls = {expectedRelayUrl};

    // Create a subscription that should persist through reconnection
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    print('Step 1: Establishing initial connection and subscription');

    // Set up debug listener to track connection events
    final debugMessages = <String>[];
    final removeDebugListener = pool.addInfoListener((message) {
      debugMessages.add(message);
      print('DEBUG: $message');
    });

    // Send initial request and verify connection
    await pool.send(req, relayUrls: relayUrls);

    // Wait for connection to establish
    await Future.delayed(Duration(milliseconds: 2000));

    // Verify initial connection
    expect(
      pool.relays.containsKey(expectedRelayUrl),
      isTrue,
      reason: 'Should have relay connection tracked',
    );

    final initialRelayState = pool.relays[expectedRelayUrl]!;
    expect(
      initialRelayState.isConnected,
      isTrue,
      reason: 'Relay should be initially connected',
    );

    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isTrue,
      reason: 'Should have active subscription',
    );

    print('Step 2: Setting up listener for reconnection events');

    // Set up listener for new events BEFORE killing relay
    final eventsAfterReconnection = <Map<String, dynamic>>[];
    late StreamSubscription eventsSubscription;

    final eventsCompleter = Completer<void>();

    eventsSubscription = pool.stream
        .where((response) => response != null && response is EventRelayResponse)
        .listen((response) {
          final eventResponse = response as EventRelayResponse;
          if (eventResponse.req.subscriptionId == req.subscriptionId) {
            eventsAfterReconnection.addAll(eventResponse.events);
            print(
              'Received ${eventResponse.events.length} events after reconnection',
            );

            // Only complete when we receive actual events (not empty responses)
            if (eventResponse.events.isNotEmpty &&
                !eventsCompleter.isCompleted) {
              eventsCompleter.complete();
            }
          }
        });

    print('Step 3: Killing relay process to simulate network disconnection');

    // Kill the current relay process
    final originalProcess = relayProcesses[0];
    originalProcess.kill(ProcessSignal.sigterm);

    // Wait for disconnection to be detected
    await Future.delayed(Duration(milliseconds: 1000));

    print('Step 4: Restarting relay process');

    // Restart the relay process
    final newProcess = await Process.start('nak', [
      'serve',
      '--port',
      port.toString(),
    ], mode: ProcessStartMode.detached);

    // Replace the process in our tracking list
    relayProcesses[0] = newProcess;

    // Give the new relay time to start up
    await Future.delayed(Duration(milliseconds: 3000));

    // Republish test events to the restarted relay
    await populateRelayWithTestEvents(port);

    print('Step 5: Waiting for automatic reconnection and events');

    // Wait for events or timeout
    try {
      await eventsCompleter.future.timeout(Duration(seconds: 10));

      expect(
        eventsAfterReconnection.isNotEmpty,
        isTrue,
        reason: 'Should receive events after reconnection',
      );

      print(
        '✓ Received ${eventsAfterReconnection.length} events after reconnection',
      );

      // Verify events have proper structure
      for (final event in eventsAfterReconnection) {
        expect(
          event.containsKey('id'),
          isTrue,
          reason: 'Event should have id field',
        );
        expect(event['id'], isA<String>(), reason: 'Event id should be string');
      }

      // Verify the relay state after reconnection and events received
      final reconnectedRelayState = pool.relays[expectedRelayUrl];
      expect(
        reconnectedRelayState,
        isNotNull,
        reason: 'Relay state should still exist after reconnection',
      );

      expect(
        reconnectedRelayState!.isConnected,
        isTrue,
        reason: 'Relay should be reconnected',
      );

      // Verify subscription is still active
      expect(
        pool.subscriptions.containsKey(req.subscriptionId),
        isTrue,
        reason: 'Subscription should still be active after reconnection',
      );
    } catch (e) {
      fail('Failed to receive events after reconnection within timeout: $e');
    } finally {
      eventsSubscription.cancel();
      removeDebugListener();
    }

    // Check debug messages for reconnection indicators
    final hasDisconnectionMessage = debugMessages.any(
      (msg) => msg.contains('Disconnected from relay'),
    );
    final hasReconnectionMessage = debugMessages.any(
      (msg) => msg.contains('Reconnected to relay'),
    );

    expect(
      hasDisconnectionMessage,
      isTrue,
      reason: 'Should have logged disconnection',
    );
    expect(
      hasReconnectionMessage,
      isTrue,
      reason: 'Should have logged reconnection',
    );

    print('✓ Reconnection test completed successfully');
    print('  - Initial connection: ✓');
    print('  - Disconnection detected: ✓');
    print('  - Reconnection successful: ✓');
    print('  - Subscriptions resent: ✓');
    print('  - Events received after reconnection: ✓');
  });

  test('should NOT reconnect after intentional unsubscribe', () async {
    final port = relayPorts[0];
    final expectedRelayUrl = 'ws://localhost:$port';
    final relayUrls = {expectedRelayUrl};

    // Create a subscription
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    print('Step 1: Establishing connection and subscription');

    // Set up debug listener
    final debugMessages = <String>[];
    final removeDebugListener = pool.addInfoListener((message) {
      debugMessages.add(message);
      print('DEBUG: $message');
    });

    await pool.send(req, relayUrls: relayUrls);

    // Wait for connection
    await Future.delayed(Duration(milliseconds: 2000));

    // Verify connection established
    expect(
      pool.relays[expectedRelayUrl]?.isConnected,
      isTrue,
      reason: 'Should be initially connected',
    );

    print('Step 2: Intentionally unsubscribing');

    // Intentionally unsubscribe
    pool.unsubscribe(req);

    // Wait for cleanup
    await Future.delayed(Duration(milliseconds: 1000));

    print('Step 3: Killing and restarting relay to test no reconnection');

    // Kill and restart relay
    final originalProcess = relayProcesses[0];
    originalProcess.kill(ProcessSignal.sigterm);

    await Future.delayed(Duration(milliseconds: 1000));

    final newProcess = await Process.start('nak', [
      'serve',
      '--port',
      port.toString(),
    ], mode: ProcessStartMode.detached);

    relayProcesses[0] = newProcess;

    // Wait longer than normal reconnection time
    await Future.delayed(Duration(milliseconds: 5000));

    print('Step 4: Verifying no reconnection occurred');

    // Verify that subscription was not restored
    expect(
      pool.subscriptions.containsKey(req.subscriptionId),
      isFalse,
      reason:
          'Subscription should remain removed after intentional unsubscribe',
    );

    // The relay might still be tracked but should not have active subscriptions
    if (pool.relays.containsKey(expectedRelayUrl)) {
      // The connection might exist but no subscriptions should be active
      expect(
        pool.subscriptions.values.any(
          (sub) => sub.targetRelays.contains(expectedRelayUrl),
        ),
        isFalse,
        reason: 'Should not have any active subscriptions to this relay',
      );
    }

    removeDebugListener();

    print('✓ Intentional disconnection test completed successfully');
    print('  - Initial connection: ✓');
    print('  - Intentional unsubscribe: ✓');
    print('  - No reconnection after restart: ✓');
  });
}
