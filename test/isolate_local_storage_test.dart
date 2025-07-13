import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Future<void> main() async {
  late ProviderContainer container;
  late StorageNotifier storage;
  late DummySigner signer;

  // Test events that will be saved and reused across tests
  late Set<Model<dynamic>> testEvents;
  late Note testNote1, testNote2, testNote3;
  late DirectMessage testDM;

  setUpAll(() async {
    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    final config = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {'wss://test1.com', 'wss://test2.com'},
        'backup': {'wss://backup.com'},
      },
      defaultRelayGroup: 'test',
    );

    await container.read(initializationProvider(config).future);
    storage = container.read(storageNotifierProvider.notifier);
    signer = DummySigner(container.read(refProvider));
    await signer.initialize();

    // Create comprehensive test dataset
    testNote1 = await PartialNote(
      'This is test note 1 with #bitcoin and #nostr tags',
      tags: {'bitcoin', 'nostr', 'test'},
    ).signWith(signer);

    testNote2 = await PartialNote(
      'Test note 2 about #lightning network',
      tags: {'lightning', 'test'},
    ).signWith(signer);

    testNote3 = await PartialNote('Simple note without tags').signWith(signer);

    testDM = await PartialDirectMessage(
      content: 'Secret test message',
      receiver: Utils.generateRandomHex64(),
    ).signWith(signer);

    testEvents = {testNote1, testNote2, testNote3, testDM};

    // Save all test events
    final saveResult = await storage.save(testEvents);
    expect(
      saveResult,
      isTrue,
      reason: 'Failed to save test events in setUpAll',
    );
  });

  setUp(() async {
    // Clear database and re-save test events before each test
    // to ensure consistent state
    await storage.clear();
    final saveResult = await storage.save(testEvents);
    expect(
      saveResult,
      isTrue,
      reason: 'Failed to re-save test events in setUp',
    );
  });

  tearDownAll(() async {
    storage.dispose();
    storage.obliterate();
    container.dispose();
  });

  group('LocalSaveIsolateOperation', () {
    test('should save single event successfully', () async {
      final newNote = await PartialNote('New single note').signWith(signer);
      final result = await storage.save({newNote});
      expect(result, isTrue);

      // Verify it was saved by querying
      final queryResult = await storage.query(
        RequestFilter(ids: {newNote.id}).toRequest(),
      );
      expect(queryResult, hasLength(1));
      expect(queryResult.first.id, equals(newNote.id));
    });

    test('should save multiple events in batch', () async {
      final note1 = await PartialNote('Batch note 1').signWith(signer);
      final note2 = await PartialNote('Batch note 2').signWith(signer);
      final note3 = await PartialNote('Batch note 3').signWith(signer);

      final batchEvents = {note1, note2, note3};
      final result = await storage.save(batchEvents);
      expect(result, isTrue);

      // Verify all were saved
      final queryResult = await storage.query(
        RequestFilter(ids: {note1.id, note2.id, note3.id}).toRequest(),
      );
      expect(queryResult, hasLength(3));
    });

    test('should handle duplicate events gracefully', () async {
      // Try to save an event that already exists
      final result = await storage.save({testNote1});
      expect(result, isTrue); // Should succeed even with duplicates
    });

    test('should handle replaceable events correctly', () async {
      // For now, just test that regular notes work with different content
      final note1 = await PartialNote('First content').signWith(signer);
      await storage.save({note1});

      final note2 = await PartialNote('Second content').signWith(signer);
      await storage.save({note2});

      // Query should return both notes (since they have different IDs)
      final result = await storage.query(
        RequestFilter(kinds: {1}, authors: {signer.pubkey}).toRequest(),
      );
      expect(result.length, greaterThanOrEqualTo(2));
    });

    test('should handle events with large content', () async {
      final largeContent = 'x' * 100000; // 100KB content
      final largeNote = await PartialNote(largeContent).signWith(signer);

      final result = await storage.save({largeNote});
      expect(result, isTrue);

      final queryResult = await storage.query(
        RequestFilter(ids: {largeNote.id}).toRequest(),
      );
      expect(queryResult.first.event.content, equals(largeContent));
    });

    test('should handle events with special characters', () async {
      const specialContent = 'Test with émojis 🚀⚡️ and ünïcödé characters 中文';
      final specialNote = await PartialNote(specialContent).signWith(signer);

      final result = await storage.save({specialNote});
      expect(result, isTrue);

      final queryResult = await storage.query(
        RequestFilter(ids: {specialNote.id}).toRequest(),
      );
      expect(queryResult.first.event.content, equals(specialContent));
    });

    test('should handle empty event set', () async {
      final result = await storage.save(<Model<dynamic>>{});
      expect(result, isTrue);
    });
  });

  group('LocalQueryIsolateOperation', () {
    test('should query by single ID', () async {
      final result = await storage.query(
        RequestFilter(ids: {testNote1.id}).toRequest(),
      );
      expect(result, hasLength(1));
      expect(result.first.id, equals(testNote1.id));
    });

    test('should query by multiple IDs', () async {
      final result = await storage.query(
        RequestFilter(ids: {testNote1.id, testNote2.id}).toRequest(),
      );
      expect(result, hasLength(2));
      expect(
        result.map((e) => e.id),
        containsAll([testNote1.id, testNote2.id]),
      );
    });

    test('should query by kinds', () async {
      final result = await storage.query(
        RequestFilter(kinds: {1}).toRequest(), // Notes
      );
      expect(result, hasLength(3)); // testNote1, testNote2, testNote3
      expect(result.every((e) => e.event.kind == 1), isTrue);
    });

    test('should query by authors', () async {
      final result = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(result, hasLength(4)); // All our test events
      expect(result.every((e) => e.event.pubkey == signer.pubkey), isTrue);
    });

    test('should query by tags', () async {
      final result = await storage.query(
        RequestFilter(
          tags: {
            '#t': {'bitcoin'},
          },
        ).toRequest(),
      );
      expect(result, hasLength(1));
      expect(result.first.id, equals(testNote1.id));
    });

    test('should query with multiple tag values', () async {
      final result = await storage.query(
        RequestFilter(
          tags: {
            '#t': {'bitcoin', 'lightning'},
          },
        ).toRequest(),
      );
      expect(result, hasLength(2)); // testNote1 and testNote2
    });

    test('should query with time range', () async {
      final now = DateTime.now();
      final oneHourAgo = now.subtract(Duration(hours: 1));
      final oneHourLater = now.add(Duration(hours: 1));

      final result = await storage.query(
        RequestFilter(since: oneHourAgo, until: oneHourLater).toRequest(),
      );
      expect(result, hasLength(4)); // All our test events should be in range
    });

    test('should return empty result for non-existent ID', () async {
      final result = await storage.query(
        RequestFilter(ids: {Utils.generateRandomHex64()}).toRequest(),
      );
      expect(result, isEmpty);
    });

    test('should return empty result for non-existent kind', () async {
      final result = await storage.query(
        RequestFilter(kinds: {99999}).toRequest(),
      );
      expect(result, isEmpty);
    });

    test('should handle complex multi-filter queries', () async {
      final result = await storage.query(
        RequestFilter(
          kinds: {1},
          authors: {signer.pubkey},
          tags: {
            '#t': {'test'},
          },
        ).toRequest(),
      );
      expect(result, hasLength(2)); // testNote1 and testNote2 have #test tag
    });

    test('should handle queries with limit', () async {
      final result = await storage.query(
        RequestFilter(kinds: {1}, limit: 2).toRequest(),
      );
      expect(result, hasLength(2));
    });

    test('should handle malformed query gracefully', () async {
      // This tests the error handling in the isolate
      try {
        // Create a request that might cause SQL issues
        final result = await storage.query(
          RequestFilter(ids: {''}).toRequest(), // Empty ID
        );
        expect(result, isEmpty); // Should handle gracefully
      } catch (e) {
        // If it throws, it should be a proper exception
        expect(e, isA<Exception>());
      }
    });
  });

  group('LocalClearIsolateOperation', () {
    test('should clear all data from storage', () async {
      // Verify we have our test data before clearing (should be exactly 4 events)
      final beforeClear = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(beforeClear, hasLength(4));

      // Clear the storage
      await storage.clear();

      // Verify all data is gone
      final afterClear = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(afterClear, isEmpty);

      // Verify we can still save new data after clearing
      final newNote = await PartialNote('Post-clear note').signWith(signer);
      final saveResult = await storage.save({newNote});
      expect(saveResult, isTrue);

      final queryResult = await storage.query(
        RequestFilter(ids: {newNote.id}).toRequest(),
      );
      expect(queryResult, hasLength(1));
    });

    test('should handle clear on empty database', () async {
      // Clear first
      await storage.clear();

      // Clear again - should not throw
      expect(storage.clear(), completes);
    });
  });

  group('Error Handling in Local Operations', () {
    test('should handle database constraint violations gracefully', () async {
      // This is harder to test without direct database access
      // but we can test edge cases that might cause issues

      final note = await PartialNote('Test note').signWith(signer);
      await storage.save({note});

      // Try to save the same note again - should handle gracefully
      final result = await storage.save({note});
      expect(result, isTrue);
    });

    test('should handle invalid event data gracefully', () async {
      // Test with events that have potential issues
      // (though most validation happens at model level)

      final noteWithEmptyContent = await PartialNote('').signWith(signer);
      final result = await storage.save({noteWithEmptyContent});
      expect(result, isTrue);
    });
  });
}
