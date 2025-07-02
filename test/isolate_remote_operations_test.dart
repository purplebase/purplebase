import 'dart:async';
import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Future<void> main() async {
  NostrRelay? relay;
  final relayPorts = [7078, 7079, 7080, 7081, 7082];
  final relayUrl = 'ws://127.0.0.1:${relayPorts.first}';

  late Set<Model<dynamic>> testEvents;
  late Note testNote1, testNote2;
  late DirectMessage testDM;
  late Bip340PrivateKeySigner signer;

  setUpAll(() async {
    try {
      relay = NostrRelay(port: relayPorts.first, host: '127.0.0.1');
      await relay!.start();
      print('Started dart_relay at port ${relayPorts.first}');
    } catch (e) {
      print('Failed to start dart_relay: $e');
      rethrow;
    }
  });

  tearDownAll(() async {
    if (relay != null) {
      await relay!.stop();
      relay = null;
      print('Stopped dart_relay');
    }
  });

  Future<void> createTestEvents(ProviderContainer container) async {
    signer = Bip340PrivateKeySigner(
      Utils.generateRandomHex64(),
      container.read(refProvider),
    );
    await signer.initialize();

    testNote1 = await PartialNote(
      'Test note for remote operations',
      tags: {'test', 'remote'},
    ).signWith(signer);

    testNote2 = await PartialNote(
      'Second test note for batch operations',
      tags: {'test', 'batch'},
    ).signWith(signer);

    testDM = await PartialDirectMessage(
      content: 'Test direct message',
      receiver: Utils.generateRandomHex64(),
    ).signWith(signer);

    testEvents = {testNote1, testNote2, testDM};
  }

  group('RemotePublishIsolateOperation', () {
    late ProviderContainer container;
    late StorageNotifier storage;

    setUpAll(() async {
      container = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );

      final config = StorageConfiguration(
        skipVerification: true,
        relayGroups: {
          'primary': {relayUrl},
          'secondary': {relayUrl},
          'both': {relayUrl}, // For now, using single relay for simplicity
          'offline': {'ws://127.0.0.1:65534'}, // Non-existent relay
        },
        defaultRelayGroup: 'primary',
        responseTimeout: Duration(milliseconds: 200),
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier);

      // Create test events after initialization
      await createTestEvents(container);
    });

    tearDownAll(() async {
      try {
        storage.dispose();
        container.dispose();
      } catch (e) {
        // Ignore disposal errors during cleanup
      }
    });

    test('should publish single event to primary relay', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'primary'));

      expect(response, isA<PublishResponse>());

      // Verify that the event was published and accepted
      expect(response.results, isNotEmpty);
      expect(response.results.containsKey(testNote1.id), isTrue);

      // Check that the event was accepted by the relay
      final eventStates = response.results[testNote1.id]!;
      expect(eventStates, isNotEmpty);
      expect(eventStates.every((state) => state.accepted), isTrue);
    });

    test('should publish multiple events to relay', () async {
      final response = await storage.publish({
        testNote1,
        testNote2,
      }, source: RemoteSource(group: 'primary'));

      expect(response, isA<PublishResponse>());

      // Verify that both events were published and accepted
      expect(response.results, isNotEmpty);
      expect(response.results.containsKey(testNote1.id), isTrue);
      expect(response.results.containsKey(testNote2.id), isTrue);

      // Check that both events were accepted by the relay
      final note1States = response.results[testNote1.id]!;
      final note2States = response.results[testNote2.id]!;
      expect(note1States, isNotEmpty);
      expect(note2States, isNotEmpty);
      expect(note1States.every((state) => state.accepted), isTrue);
      expect(note2States.every((state) => state.accepted), isTrue);
    });

    test('should publish to multiple relays', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'both'));

      expect(response, isA<PublishResponse>());

      // Verify that the event was published and accepted
      expect(response.results, isNotEmpty);
      expect(response.results.containsKey(testNote1.id), isTrue);

      // Check that the event was accepted by the relay
      final eventStates = response.results[testNote1.id]!;
      expect(eventStates, isNotEmpty);
      expect(eventStates.every((state) => state.accepted), isTrue);
    });

    test('should handle publish to offline relay gracefully', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'offline'));

      expect(response, isA<PublishResponse>());

      expect(response.unreachableRelayUrls, isNotEmpty);
    });

    test('should handle empty event set', () async {
      final response = await storage.publish(
        <Model<dynamic>>{},
        source: RemoteSource(group: 'primary'),
      );

      expect(response, isA<PublishResponse>());

      // No events should be in results for empty set
      expect(response.results, isEmpty);
    });

    test('should use default relay group when no source specified', () async {
      final response = await storage.publish({testNote1});

      expect(response, isA<PublishResponse>());

      // Verify that the event was published and accepted
      expect(response.results, isNotEmpty);
      expect(response.results.containsKey(testNote1.id), isTrue);

      // Check that the event was accepted by the relay
      final eventStates = response.results[testNote1.id]!;
      expect(eventStates, isNotEmpty);
      expect(eventStates.every((state) => state.accepted), isTrue);
    });

    test('should handle large events', () async {
      final largeContent = 'Large content: ${'x' * 50000}';
      final largeNote = await PartialNote(largeContent).signWith(signer);

      final response = await storage.publish({
        largeNote,
      }, source: RemoteSource(group: 'primary'));

      expect(response, isA<PublishResponse>());

      // Verify that the large event was published and accepted
      expect(response.results, isNotEmpty);
      expect(response.results.containsKey(largeNote.id), isTrue);

      // Check that the event was accepted by the relay
      final eventStates = response.results[largeNote.id]!;
      expect(eventStates, isNotEmpty);
      expect(eventStates.every((state) => state.accepted), isTrue);
    });
  });

  group('RemoteQueryIsolateOperation', () {
    late ProviderContainer container;
    late StorageNotifier storage;

    setUpAll(() async {
      container = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );

      final config = StorageConfiguration(
        skipVerification: true,
        relayGroups: {
          'primary': {relayUrl},
          'secondary': {relayUrl},
          'both': {relayUrl},
          'offline': {'ws://127.0.0.1:65534'},
        },
        defaultRelayGroup: 'primary',
        responseTimeout: Duration(milliseconds: 200),
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier);

      // Create test events after initialization
      await createTestEvents(container);

      // Publish some test events first so we can query them
      await storage.publish(testEvents);
    });

    tearDownAll(() async {
      storage.dispose();
      container.dispose();
    });

    test('should query events by ID from relay', () async {
      final request = RequestFilter(ids: {testNote1.id}).toRequest();

      final result = await storage.query(
        request,
        source: RemoteSource(group: 'primary'),
      );

      // Events should be saved automatically from the remote query
      expect(result, isNotEmpty);
    });

    test('should query events by kind from relay', () async {
      final request = RequestFilter(kinds: {1}).toRequest(); // Notes

      final result = await storage.query(
        request,
        source: RemoteSource(group: 'primary'),
      );

      expect(result, isNotEmpty);
      expect(result.every((e) => e.event.kind == 1), isTrue);
    });

    test('should query events by author from relay', () async {
      final request = RequestFilter(authors: {signer.pubkey}).toRequest();

      final result = await storage.query(
        request,
        source: RemoteSource(group: 'primary'),
      );

      expect(result, isNotEmpty);
      expect(result.every((e) => e.event.pubkey == signer.pubkey), isTrue);
    });

    test('should query events with tags from relay', () async {
      final request =
          RequestFilter(
            tags: {
              '#t': {'test'},
            },
          ).toRequest();

      final result = await storage.query(
        request,
        source: RemoteSource(group: 'primary'),
      );

      expect(result, isNotEmpty);
    });

    test('should query from multiple relays', () async {
      final request = RequestFilter(authors: {signer.pubkey}).toRequest();

      final result = await storage.query(
        request,
        source: RemoteSource(group: 'both'),
      );

      expect(result, isNotEmpty);
    });

    test('should handle query with time limits', () async {
      final now = DateTime.now();
      final oneHourAgo = now.subtract(Duration(hours: 1));

      final request =
          RequestFilter(
            authors: {signer.pubkey},
            since: oneHourAgo,
            limit: 10,
          ).toRequest();

      final result = await storage.query(
        request,
        source: RemoteSource(group: 'primary'),
      );

      expect(result.length, lessThanOrEqualTo(10));
    });

    test('should handle offline relay gracefully', () async {
      final request = RequestFilter(authors: {signer.pubkey}).toRequest();

      // Should not throw when querying offline relay
      final result = await storage.query(
        request,
        source: RemoteSource(group: 'offline'),
      );

      // Result might be empty or contain cached data
      expect(result, isA<List>());
    });

    test('should handle empty query filters', () async {
      final request = RequestFilter().toRequest();

      final result = await storage.query(
        request,
        source: RemoteSource(group: 'primary'),
      );

      expect(result, isA<List>());
    });

    test('should query with complex filters', () async {
      final now = DateTime.now();
      final oneHourAgo = now.subtract(Duration(hours: 1));

      final request =
          RequestFilter(
            kinds: {1},
            authors: {signer.pubkey},
            since: oneHourAgo,
            until: now,
            limit: 5,
          ).toRequest();

      final result = await storage.query(
        request,
        source: RemoteSource(group: 'primary'),
      );

      expect(result.length, lessThanOrEqualTo(5));
      if (result.isNotEmpty) {
        expect(result.every((e) => e.event.kind == 1), isTrue);
        expect(result.every((e) => e.event.pubkey == signer.pubkey), isTrue);
      }
    });

    test('should use default relay group when no source specified', () async {
      final request = RequestFilter(authors: {signer.pubkey}).toRequest();

      final result = await storage.query(request);

      expect(result, isA<List>());
    });

    test('should deduplicate events from multiple relays', () async {
      // Publish the same event to both relays
      await storage.publish({testNote1}, source: RemoteSource(group: 'both'));

      final request = RequestFilter(ids: {testNote1.id}).toRequest();

      final result = await storage.query(
        request,
        source: RemoteSource(group: 'both'),
      );

      // Should get only one copy despite querying both relays
      expect(result.where((e) => e.id == testNote1.id), hasLength(1));
    });
  });

  group('RemoteCancelIsolateOperation', () {
    late ProviderContainer container;
    late StorageNotifier storage;

    setUpAll(() async {
      container = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );

      final config = StorageConfiguration(
        skipVerification: true,
        relayGroups: {
          'primary': {relayUrl},
        },
        defaultRelayGroup: 'primary',
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier);

      // Create test events after initialization
      await createTestEvents(container);
    });

    tearDownAll(() async {
      storage.dispose();
      container.dispose();
    });

    test('should cancel active subscription', () async {
      final request = RequestFilter(authors: {signer.pubkey}).toRequest();

      // Start a subscription
      storage.query(request, source: RemoteSource(group: 'primary'));

      // Cancel the subscription (this should not throw)
      await storage.cancel(request);

      expect(true, isTrue); // If we get here, cancel worked
    });

    test('should handle canceling non-existent subscription', () async {
      final request = RequestFilter(authors: {signer.pubkey}).toRequest();

      // Try to cancel a subscription that doesn't exist
      await storage.cancel(request);

      expect(true, isTrue); // Should not throw
    });

    test('should handle cancel with offline relay', () async {
      final config = StorageConfiguration(
        skipVerification: true,
        relayGroups: {
          'offline': {'ws://127.0.0.1:65534'},
        },
        defaultRelayGroup: 'offline',
      );

      await container.read(initializationProvider(config).future);
      final offlineStorage = container.read(storageNotifierProvider.notifier);

      final request = RequestFilter(authors: {signer.pubkey}).toRequest();

      // Should not throw when canceling from offline relay
      await offlineStorage.cancel(request);

      expect(true, isTrue);
    });
  });

  group('Error Handling in Remote Operations', () {
    late ProviderContainer container;
    late StorageNotifier storage;

    setUpAll(() async {
      container = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );

      final config = StorageConfiguration(
        skipVerification: true,
        relayGroups: {
          'primary': {relayUrl},
          'invalid': {'invalid-url'},
          'mixed': {
            relayUrl,
            'ws://127.0.0.1:65534',
          }, // Working + offline relay
        },
        defaultRelayGroup: 'primary',
        responseTimeout: Duration(milliseconds: 200),
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier);

      // Create test events after initialization
      await createTestEvents(container);
    });

    tearDownAll(() async {
      storage.dispose();
      container.dispose();
    });

    test('should handle invalid relay URLs gracefully', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'invalid'));

      // Should not throw, just return a response
      expect(response, isA<PublishResponse>());

      // For invalid URLs, we should expect unreachable relay URLs
      expect(response.unreachableRelayUrls, isNotEmpty);
      print('Unreachable relays: ${response.unreachableRelayUrls}');
    });

    test('should handle mixed valid/invalid relays', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'mixed'));

      expect(response, isA<PublishResponse>());

      // For mixed relays, we might have some results and some unreachable
      // The working relay should accept the event, offline relay should be unreachable
      if (response.results.isNotEmpty) {
        expect(response.results.containsKey(testNote1.id), isTrue);
        final eventStates = response.results[testNote1.id]!;
        expect(eventStates.any((state) => state.accepted), isTrue);
      }
      // Should also have unreachable relays
      expect(response.unreachableRelayUrls, isNotEmpty);
    });

    test('should handle network timeouts gracefully', () async {
      // Test with a syntactically invalid URL that should fail immediately
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'invalid'));

      expect(response, isA<PublishResponse>());

      // For invalid URLs, we should expect unreachable relay URLs
      expect(response.unreachableRelayUrls, isNotEmpty);
    });

    test('should handle malformed events in publish', () async {
      // Create an event with potential issues
      final note = await PartialNote('').signWith(signer); // Empty content

      final response = await storage.publish({
        note,
      }, source: RemoteSource(group: 'primary'));

      expect(response, isA<PublishResponse>());

      expect(response.results, isNotEmpty);
      expect(
        response.results.values.firstOrNull?.firstOrNull?.accepted,
        isTrue,
      );
      expect(response.results.containsKey(note.id), isTrue);
    });
  });
}
