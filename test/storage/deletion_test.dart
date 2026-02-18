import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/test_container.dart';

void main() {
  late ProviderContainer container;
  late PurplebaseStorageNotifier storage;
  late DummySigner signer;

  setUpAll(() async {
    container = await createStorageTestContainer();
    storage = container.storage;
    signer = DummySigner(container.ref);
    await signer.signIn();
  });

  setUp(() async {
    await storage.clear();
  });

  tearDownAll(() async {
    await container.tearDown();
  });

  group('Deletion via storage.delete()', () {
    test('deletes a single event', () async {
      final note = await PartialNote('delete me').signWith(signer);
      await storage.save({note});

      var result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(result, hasLength(1));

      await storage.delete({note.id});

      result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(result, isEmpty);
    });

    test('deletes multiple events', () async {
      final note1 = await PartialNote('del 1').signWith(signer);
      final note2 = await PartialNote('del 2').signWith(signer);
      final keep = await PartialNote('keep').signWith(signer);
      await storage.save({note1, note2, keep});

      await storage.delete({note1.id, note2.id});

      final result = await storage.query(
        RequestFilter(authors: {signer.pubkey}, kinds: {1}).toRequest(),
      );
      expect(result, hasLength(1));
      expect(result.first.id, keep.id);
    });

    test('deleting non-existent ID does not throw', () async {
      await expectLater(
        storage.delete({'nonexistent_id_12345'}),
        completes,
      );
    });

    test('deleting empty set does nothing', () async {
      final note = await PartialNote('keep me').signWith(signer);
      await storage.save({note});

      await storage.delete(<String>{});

      final result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(result, hasLength(1));
    });
  });
}
