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

  group('Pruning via storage', () {
    test('prune completes without error', () async {
      final note = await PartialNote('prune test').signWith(signer);
      await storage.save({note});

      await expectLater(
        storage.prune(olderThan: Duration(days: 30)),
        completes,
      );
    });

    test('prune with default duration completes', () async {
      await expectLater(storage.prune(), completes);
    });
  });
}
