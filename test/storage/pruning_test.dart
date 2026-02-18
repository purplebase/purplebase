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

  group('Storage-level pruning', () {
    test('prune completes successfully', () async {
      final note = await PartialNote('prune me').signWith(signer);
      await storage.save({note});
      await expectLater(storage.prune(olderThan: Duration(days: 30)), completes);
    });

    test('prune with default duration', () async {
      await expectLater(storage.prune(), completes);
    });

    test('prune on empty database', () async {
      await expectLater(storage.prune(), completes);
    });

    test('prune does not affect recently saved events', () async {
      final note = await PartialNote('fresh event').signWith(signer);
      await storage.save({note});

      await storage.prune(olderThan: Duration(days: 1));

      final result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(result, hasLength(1));
    });
  });
}
