import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Future<void> main() async {
  Process? nakProcess;
  late int relayPort;
  late String relayUrl;

  setUpAll(() async {
    relayPort = 40000 + Random().nextInt(20000); // Random high port
    relayUrl = 'ws://localhost:$relayPort';

    print('Starting nak relay on port $relayPort...');
    try {
      final result = await Process.run('nak', ['--version']);
      if (result.exitCode != 0) {
        throw Exception(
          '`nak --version` failed with exit code ${result.exitCode}',
        );
      }
    } catch (e) {
      print(
        'nak CLI not found or not working. Please install it to run these tests.',
      );
      print('You can install it with `cargo install nak`.');
      print('See https://github.com/studiokaiji/nak for more info.');
      print('Error: $e');
      fail('nak CLI not available. Skipping remote operation tests.');
    }

    nakProcess = await Process.start('nak', ['serve', '--port', '$relayPort']);
    nakProcess!.stdout.transform(utf8.decoder).listen((data) {
      if (data.contains('listening on')) {
        print('Nak relay started and listening.');
      }
    });
    nakProcess!.stderr
        .transform(utf8.decoder)
        .listen((data) => print('nak_stderr: $data'));

    // Wait for relay to be ready
    await Future.delayed(const Duration(seconds: 2));
    print('Nak relay should be running.');
  });

  tearDownAll(() {
    if (nakProcess != null) {
      print('Stopping nak relay...');
      nakProcess!.kill(ProcessSignal.sigint);
      nakProcess = null;
      print('Nak relay stopped.');
    }
  });

  late ProviderContainer container;
  late StorageNotifier storage;
  late DummySigner signer;
  late String testDbPath;

  // Test events - will be created after initialization
  late Set<Model<dynamic>> testEvents;
  late Note testNote1, testNote2;
  late DirectMessage testDM;

  void createTestEvents() {
    testNote1 = PartialNote(
      'Test note for remote operations',
      tags: {'test', 'remote'},
    ).dummySign(signer.pubkey);

    testNote2 = PartialNote(
      'Second test note for batch operations',
      tags: {'test', 'batch'},
    ).dummySign(signer.pubkey);

    testDM = PartialDirectMessage(
      content: 'Test direct message',
      receiver: Utils.generateRandomHex64(),
    ).dummySign(signer.pubkey);

    testEvents = {testNote1, testNote2, testDM};
  }

  setUpAll(() async {
    testDbPath = 'test_remote_ops_${Random().nextInt(100000)}.db';

    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    signer = DummySigner(container.read(refProvider));
    await signer.initialize();
  });

  tearDownAll(() async {
    storage.dispose();
    storage.obliterateDatabase();
    container.dispose();
  });

  group('RemotePublishIsolateOperation', () {
    setUp(() async {
      final config = StorageConfiguration(
        databasePath: testDbPath,
        skipVerification: true,
        relayGroups: {
          'primary': {relayUrl},
          'secondary': {relayUrl},
          'both': {relayUrl},
          'offline': {'ws://localhost:99999'}, // Non-existent relay
        },
        defaultRelayGroup: 'primary',
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier);

      // Create test events after initialization
      createTestEvents();
    });

    test('should publish single event to primary relay', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'primary'));

      expect(response, isA<PublishResponse>());
    });

    test('should publish multiple events to relay', () async {
      final response = await storage.publish({
        testNote1,
        testNote2,
      }, source: RemoteSource(group: 'primary'));

      expect(response, isA<PublishResponse>());
    });

    test('should publish to multiple relays', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'both'));

      expect(response, isA<PublishResponse>());
    });

    test('should handle publish to offline relay gracefully', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'offline'));

      expect(response, isA<PublishResponse>());
    });

    test('should handle empty event set', () async {
      final response = await storage.publish(
        <Model<dynamic>>{},
        source: RemoteSource(group: 'primary'),
      );

      expect(response, isA<PublishResponse>());
    });

    test('should use default relay group when no source specified', () async {
      final response = await storage.publish({testNote1});

      expect(response, isA<PublishResponse>());
    });

    test('should handle large events', () async {
      final largeContent = 'Large content: ${'x' * 50000}';
      final largeNote = await PartialNote(largeContent).signWith(signer);

      final response = await storage.publish({
        largeNote,
      }, source: RemoteSource(group: 'primary'));

      expect(response, isA<PublishResponse>());
    });
  });

  group('RemoteQueryIsolateOperation', () {
    setUp(() async {
      final config = StorageConfiguration(
        databasePath: testDbPath,
        skipVerification: true,
        relayGroups: {
          'primary': {relayUrl},
          'secondary': {relayUrl},
          'both': {relayUrl},
          'offline': {'ws://localhost:99999'},
        },
        defaultRelayGroup: 'primary',
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier);

      // Create test events after initialization
      createTestEvents();

      // Publish some test events first so we can query them
      await storage.publish(testEvents, source: RemoteSource(group: 'primary'));
      await Future.delayed(
        const Duration(seconds: 1),
      ); // Give time for events to propagate
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
      await Future.delayed(Duration(seconds: 1));

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
    setUp(() async {
      final config = StorageConfiguration(
        databasePath: testDbPath,
        skipVerification: true,
        relayGroups: {
          'primary': {relayUrl},
        },
        defaultRelayGroup: 'primary',
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier);

      // Create test events after initialization
      createTestEvents();
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
        databasePath: testDbPath,
        skipVerification: true,
        relayGroups: {
          'offline': {'ws://localhost:99999'},
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
    setUp(() async {
      final config = StorageConfiguration(
        databasePath: testDbPath,
        skipVerification: true,
        relayGroups: {
          'primary': {relayUrl},
          'invalid': {'invalid-url'},
          'mixed': {relayUrl, 'ws://localhost:99999'},
        },
        defaultRelayGroup: 'primary',
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier);

      // Create test events after initialization
      createTestEvents();
    });

    test('should handle invalid relay URLs gracefully', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'invalid'));

      // Should not throw, just return a response
      expect(response, isA<PublishResponse>());
    });

    test('should handle mixed valid/invalid relays', () async {
      final response = await storage.publish({
        testNote1,
      }, source: RemoteSource(group: 'mixed'));

      expect(response, isA<PublishResponse>());
    });

    test('should handle network timeouts gracefully', () async {
      // This is harder to test without mock servers, but we can test
      // with unreachable addresses
      final config = StorageConfiguration(
        databasePath: testDbPath,
        skipVerification: true,
        relayGroups: {
          'timeout': {'ws://192.0.2.1:7777'}, // RFC 5737 test address
        },
        defaultRelayGroup: 'timeout',
      );

      await container.read(initializationProvider(config).future);
      final timeoutStorage = container.read(storageNotifierProvider.notifier);

      final response = await timeoutStorage.publish({
        testNote1,
      }, source: RemoteSource(group: 'timeout'));

      expect(response, isA<PublishResponse>());
    });

    test('should handle malformed events in publish', () async {
      // Create an event with potential issues
      final note = await PartialNote('').signWith(signer); // Empty content

      final response = await storage.publish({
        note,
      }, source: RemoteSource(group: 'primary'));

      expect(response, isA<PublishResponse>());
    });

    // test('should handle relay disconnection during operation', () async {
    //   // Start an operation
    //   final publishFuture = storage.publish({
    //     testNote1,
    //   }, source: RemoteSource(group: 'primary'));

    //   // Stop the relay mid-operation
    //   await stopMockRelay('primary');

    //   // Operation should complete (possibly with errors)
    //   final response = await publishFuture;
    //   expect(response, isA<PublishResponse>());
    // });
  });
}
