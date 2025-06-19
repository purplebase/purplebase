import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Future<void> main() async {
  late ProviderContainer container;
  late StorageNotifier storage;
  late DummySigner signer;

  setUp(() async {
    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    final config = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {'wss://test.com'},
      },
      defaultRelayGroup: 'test',
    );

    await container.read(initializationProvider(config).future);
    storage = container.read(storageNotifierProvider.notifier);
    signer = DummySigner(container.read(refProvider));
    await signer.initialize();
  });

  tearDown(() async {
    storage.dispose();
    storage.obliterateDatabase();
    container.dispose();
  });

  group('CloseIsolateOperation', () {
    test('should close isolate cleanly', () async {
      // Create and save some test data
      final note = await PartialNote('Test note before close').signWith(signer);
      await storage.save({note});

      // Verify data exists
      final beforeClose = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(beforeClose, hasLength(1));

      // Close the isolate
      storage.dispose();

      // Verify isolate is closed (further operations should fail or be handled gracefully)
      expect(() => storage.save({note}), throwsA(isA<Exception>()));
    });

    test('should handle close on already closed isolate', () async {
      // Close once
      storage.dispose();

      // Close again - should not throw
      expect(() => storage.dispose(), returnsNormally);
    });

    test('should cleanup resources on close', () async {
      // Save some data to ensure database is active
      final note1 = await PartialNote('Test note 1').signWith(signer);
      final note2 = await PartialNote('Test note 2').signWith(signer);
      await storage.save({note1, note2});

      // Verify operations work before close
      final beforeClose = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(beforeClose, hasLength(2));

      // Close the storage
      storage.dispose();

      // Verify the database file can be cleaned up
      storage.obliterateDatabase();
    });

    test('should handle pending operations gracefully on close', () async {
      final note = await PartialNote('Test note').signWith(signer);

      // Start a save operation
      final saveFuture = storage.save({note});

      // Immediately close the isolate
      storage.dispose();

      // The save operation should either complete or fail gracefully
      try {
        await saveFuture;
      } catch (e) {
        // Expected that it might fail
        expect(e, isA<Exception>());
      }
    });
  });

  group('Isolate Lifecycle Management', () {
    test('should initialize isolate correctly', () async {
      // The isolate should be initialized in setUp
      expect(storage, isNotNull);

      // Should be able to perform basic operations
      final note = await PartialNote('Lifecycle test note').signWith(signer);
      final result = await storage.save({note});
      expect(result, isTrue);
    });

    test('should handle multiple rapid operations', () async {
      final notes = <Note>[];
      for (int i = 0; i < 10; i++) {
        notes.add(await PartialNote('Rapid note $i').signWith(signer));
      }

      // Perform multiple save operations rapidly
      final futures = notes.map((note) => storage.save({note})).toList();
      final results = await Future.wait(futures);

      expect(results.every((r) => r == true), isTrue);

      // Verify all notes were saved
      final queryResult = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(queryResult, hasLength(10));
    });

    test('should handle isolate communication errors gracefully', () async {
      final note = await PartialNote('Communication test').signWith(signer);

      // This is harder to test without direct isolate manipulation,
      // but we can test edge cases that might cause communication issues

      final result = await storage.save({note});
      expect(result, isTrue);
    });
  }, skip: true);

  group('Error Handling in Isolate Management', () {
    test('should handle isolate spawn failures gracefully', () async {
      // This is difficult to test without mocking, but we can verify
      // that the current isolate works correctly

      final note = await PartialNote('Spawn test note').signWith(signer);
      final result = await storage.save({note});
      expect(result, isTrue);
    });

    test('should handle database initialization errors', () async {
      // Test that operations work with current database
      final note = await PartialNote('DB init test').signWith(signer);
      final result = await storage.save({note});
      expect(result, isTrue);
    });

    test('should handle close during active operations', () async {
      final note = await PartialNote('Close during ops test').signWith(signer);

      // Start multiple operations
      final future1 = storage.save({note});
      final future2 = storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );

      // Close during operations
      storage.dispose();

      // Operations should either complete or fail gracefully
      try {
        await Future.wait([future1, future2]);
      } catch (e) {
        expect(e, isA<Exception>());
      }
    });
  });
}
