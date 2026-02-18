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

  group('NIP-09 deletion via storage', () {
    test('delete removes events from local storage', () async {
      final note = await PartialNote('to be deleted').signWith(signer);
      await storage.save({note});

      // Verify present
      var result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(result, hasLength(1));

      // Delete
      await storage.delete({note.id});

      // Verify gone
      result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(result, isEmpty);
    });

    test('delete multiple events', () async {
      final note1 = await PartialNote('delete me 1').signWith(signer);
      final note2 = await PartialNote('delete me 2').signWith(signer);
      final note3 = await PartialNote('keep me').signWith(signer);
      await storage.save({note1, note2, note3});

      await storage.delete({note1.id, note2.id});

      final result = await storage.query(
        RequestFilter(authors: {signer.pubkey}, kinds: {1}).toRequest(),
      );
      expect(result, hasLength(1));
      expect(result.first.id, note3.id);
    });

    test('delete non-existent event does not throw', () async {
      await expectLater(
        storage.delete({'non_existent_id'}),
        completes,
      );
    });
  });
}
