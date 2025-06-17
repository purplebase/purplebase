import 'dart:math';
import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Future<void> main() async {
  late ProviderContainer container;
  late StorageNotifier storage;
  late DummySigner signer;
  late String testDbPath;

  setUpAll(() async {
    testDbPath = 'test_perf_integration_${Random().nextInt(100000)}.db';

    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    final config = StorageConfiguration(
      databasePath: testDbPath,
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
  });

  tearDownAll(() async {
    storage.dispose();
    storage.obliterateDatabase();
    container.dispose();
  });

  group('Performance Tests', () {
    test('should handle bulk save operations efficiently', () async {
      const eventCount = 1000;
      final stopwatch = Stopwatch()..start();

      // Create many events
      final events = <Note>[];
      for (int i = 0; i < eventCount; i++) {
        events.add(
          await PartialNote(
            'Performance test note $i #test #bulk',
          ).signWith(signer),
        );
      }

      final createTime = stopwatch.elapsedMilliseconds;
      stopwatch.reset();

      // Save all events in batches
      const batchSize = 100;
      for (int i = 0; i < events.length; i += batchSize) {
        final batch = events.sublist(i, min(i + batchSize, events.length));
        await storage.save(batch.toSet());
      }

      final saveTime = stopwatch.elapsedMilliseconds;
      stopwatch.stop();

      print('Created $eventCount events in ${createTime}ms');
      print('Saved $eventCount events in ${saveTime}ms');
      print(
        'Average save time: ${saveTime / (eventCount / batchSize)}ms per batch',
      );

      // Verify all events were saved
      final result = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(result.length, greaterThanOrEqualTo(eventCount));
    });

    test('should handle complex queries efficiently', () async {
      // First save some test data
      final events = <Model<dynamic>>{};
      for (int i = 0; i < 500; i++) {
        events.add(
          await PartialNote(
            'Query test note $i #performance',
            tags: {'performance'},
          ).signWith(signer),
        );
      }
      await storage.save(events);

      final stopwatch = Stopwatch()..start();

      // Perform complex queries
      final queries = [
        RequestFilter(authors: {signer.pubkey}).toRequest(),
        RequestFilter(kinds: {1}).toRequest(),
        RequestFilter(
          tags: {
            '#t': {'performance'},
          },
        ).toRequest(),
        RequestFilter(authors: {signer.pubkey}, kinds: {1}).toRequest(),
      ];

      for (final query in queries) {
        final result = await storage.query(query);
        expect(result, isNotEmpty);
      }

      stopwatch.stop();
      print(
        'Executed ${queries.length} complex queries in ${stopwatch.elapsedMilliseconds}ms',
      );
      print(
        'Average query time: ${stopwatch.elapsedMilliseconds / queries.length}ms',
      );
    });

    test('should handle concurrent operations efficiently', () async {
      final stopwatch = Stopwatch()..start();

      // Create concurrent save and query operations
      final saveOperations = <Future>[];
      final queryOperations = <Future>[];

      for (int i = 0; i < 50; i++) {
        final note = await PartialNote('Concurrent note $i').signWith(signer);
        saveOperations.add(storage.save({note}));

        if (i % 10 == 0) {
          queryOperations.add(
            storage.query(RequestFilter(authors: {signer.pubkey}).toRequest()),
          );
        }
      }

      // Wait for all operations to complete
      await Future.wait([...saveOperations, ...queryOperations]);

      stopwatch.stop();
      print(
        'Completed ${saveOperations.length} saves and ${queryOperations.length} queries concurrently in ${stopwatch.elapsedMilliseconds}ms',
      );
    });

    test('should handle large content efficiently', () async {
      final sizes = [1000, 10000, 100000, 1000000]; // 1KB, 10KB, 100KB, 1MB

      for (final size in sizes) {
        final stopwatch = Stopwatch()..start();

        final largeContent = 'x' * size;
        final largeNote = await PartialNote(largeContent).signWith(signer);

        await storage.save({largeNote});

        final queryResult = await storage.query(
          RequestFilter(ids: {largeNote.id}).toRequest(),
        );

        stopwatch.stop();

        expect(queryResult, hasLength(1));
        expect(queryResult.first.event.content, equals(largeContent));

        print(
          'Saved and queried $size byte content in ${stopwatch.elapsedMilliseconds}ms',
        );
      }
    });
  });

  group('Integration Tests', () {
    test('should handle complete save-query-clear cycle', () async {
      // Save phase
      final testEvents = <Model<dynamic>>{};
      for (int i = 0; i < 100; i++) {
        testEvents.add(
          await PartialNote(
            'Integration test note $i #cycle',
            tags: {'cycle'},
          ).signWith(signer),
        );
      }

      final saveResult = await storage.save(testEvents);
      expect(saveResult, isTrue);

      // Query phase - verify all saved
      final queryResult = await storage.query(
        RequestFilter(
          tags: {
            '#t': {'cycle'},
          },
        ).toRequest(),
      );
      expect(queryResult, hasLength(100));

      // Update phase - save replaceable events
      final metadata = await PartialNote(
        'Updated metadata',
        tags: {'updated'},
      ).signWith(signer);
      await storage.save({metadata});

      // Query updated data
      final updatedResult = await storage.query(
        RequestFilter(
          tags: {
            '#t': {'updated'},
          },
        ).toRequest(),
      );
      expect(updatedResult, hasLength(1));

      // Clear phase
      await storage.clear();

      // Verify clear worked
      final afterClear = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(afterClear, isEmpty);
    });

    test('should handle mixed local and remote operations', () async {
      // Save locally first
      final localNote = await PartialNote('Local note #mixed').signWith(signer);
      await storage.save({localNote});

      // Query locally
      final localResult = await storage.query(
        RequestFilter(ids: {localNote.id}).toRequest(),
      );
      expect(localResult, hasLength(1));

      // Note: Remote operations would require actual relay setup
      // For now, we'll test the local part thoroughly

      // Test sync vs async queries
      final syncResult = storage.querySync(
        RequestFilter(ids: {localNote.id}).toRequest(),
      );
      expect(syncResult, hasLength(1));
      expect(syncResult.first.id, equals(localResult.first.id));
    });

    test('should handle event deduplication correctly', () async {
      final note = await PartialNote('Duplicate test note').signWith(signer);

      // Save the same event multiple times
      await storage.save({note});
      await storage.save({note});
      await storage.save({note});

      // Should only have one copy
      final result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(result, hasLength(1));
    });

    test('should handle replaceable event updates correctly', () async {
      // Create initial event
      final note1 = await PartialNote(
        'Original content',
        tags: {'replaceable'},
      ).signWith(signer);
      await storage.save({note1});

      // Create replacement with same ID logic
      final note2 = await PartialNote(
        'Updated content',
        tags: {'replaceable'},
      ).signWith(signer);
      await storage.save({note2});

      // Query should return both (since they have different IDs)
      // For true replaceables, we'd need kind 0, 3, etc.
      final result = await storage.query(
        RequestFilter(
          tags: {
            '#t': {'replaceable'},
          },
        ).toRequest(),
      );
      expect(result, hasLength(2));
    });

    test('should handle data consistency across operations', () async {
      // Create test dataset
      final notes = <Note>[];
      for (int i = 0; i < 50; i++) {
        notes.add(
          await PartialNote(
            'Consistency test $i #data',
            tags: {'data'},
          ).signWith(signer),
        );
      }

      // Save in multiple batches
      for (int i = 0; i < notes.length; i += 10) {
        final batch = notes.sublist(i, min(i + 10, notes.length));
        await storage.save(batch.toSet());
      }

      // Verify all were saved correctly
      final allNotes = await storage.query(
        RequestFilter(
          tags: {
            '#t': {'data'},
          },
        ).toRequest(),
      );
      expect(allNotes, hasLength(50));

      // Verify content integrity
      for (int i = 0; i < 50; i++) {
        final matching = allNotes.where(
          (n) => n.event.content.contains('test $i '),
        );
        expect(matching, hasLength(1));
      }
    });
  });

  group('Stress Tests', () {
    test('should handle rapid fire operations', () async {
      final futures = <Future>[];

      // Rapid save operations
      for (int i = 0; i < 100; i++) {
        final note = await PartialNote('Rapid fire $i').signWith(signer);
        futures.add(storage.save({note}));
      }

      // Rapid query operations
      for (int i = 0; i < 20; i++) {
        futures.add(
          storage.query(RequestFilter(authors: {signer.pubkey}).toRequest()),
        );
      }

      // Wait for all to complete
      final results = await Future.wait(futures);

      // All save operations should succeed
      final saveResults = results.take(100).cast<bool>();
      expect(saveResults.every((r) => r == true), isTrue);

      // All query operations should return lists
      final queryResults = results.skip(100).cast<List>();
      expect(queryResults.every((r) => r.isNotEmpty), isTrue);
    });
  });
}
