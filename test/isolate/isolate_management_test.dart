import 'package:models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for isolate lifecycle management.
///
/// These tests verify the isolate's ability to:
/// - Initialize and close cleanly
/// - Handle concurrent operations
/// - Manage pending operations during close
void main() {
  late ProviderContainer container;
  late StorageNotifier storage;
  late DummySigner signer;

  setUp(() async {
    container = await createStorageTestContainer();
    storage = container.storage;
    signer = DummySigner(container.ref);
    await signer.signIn();
  });

  tearDown(() async {
    storage.dispose();
    storage.obliterate();
    container.dispose();
  });

  group('Close operations', () {
    test('closes isolate cleanly', () async {
      final note = await PartialNote('Test note before close').signWith(signer);
      await storage.save({note});

      final beforeClose = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(beforeClose, hasLength(1));

      storage.dispose();

      expect(() => storage.save({note}), throwsA(isA<Exception>()));
    });

    test('handles close on already closed isolate', () async {
      storage.dispose();

      expect(() => storage.dispose(), returnsNormally);
    });

    test('cleans up resources on close', () async {
      final notes = await Future.wait([
        PartialNote('Test note 1').signWith(signer),
        PartialNote('Test note 2').signWith(signer),
      ]);
      await storage.save(notes.toSet());

      final beforeClose = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(beforeClose, hasLength(2));

      storage.dispose();
      storage.obliterate();
    });

    test('handles pending operations gracefully on close', () async {
      final note = await PartialNote('Test note').signWith(signer);

      final saveFuture = storage.save({note});

      storage.dispose();

      try {
        await saveFuture;
      } catch (e) {
        expect(e, isA<Exception>());
      }
    });
  });

  group('Lifecycle management', () {
    test('initializes isolate correctly', () async {
      expect(storage, isNotNull);

      final note = await PartialNote('Lifecycle test note').signWith(signer);
      final result = await storage.save({note});
      expect(result, isTrue);
    });

    test('handles multiple rapid operations', () async {
      final notes = <Note>[];
      for (var i = 0; i < 10; i++) {
        notes.add(await PartialNote('Rapid note $i').signWith(signer));
      }

      final futures = notes.map((note) => storage.save({note})).toList();
      final results = await Future.wait(futures);

      expect(results.every((r) => r == true), isTrue);

      final queryResult = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(queryResult, hasLength(10));
    });
  });

  group('Error handling', () {
    test('handles close during active operations', () async {
      final note = await PartialNote('Close during ops test').signWith(signer);

      final future1 = storage.save({note});
      final future2 = storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );

      storage.dispose();

      try {
        await Future.wait([future1, future2]);
      } catch (e) {
        expect(e, isA<Exception>());
      }
    });
  });
}
