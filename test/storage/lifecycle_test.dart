import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/test_container.dart';

void main() {
  group('Storage lifecycle', () {
    test('initializes with in-memory database', () async {
      final container = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );

      final config = StorageConfiguration(
        skipVerification: true,
        defaultRelays: {
          'test': {'wss://test.relay'},
        },
        defaultQuerySource: LocalSource(),
      );

      await container.read(initializationProvider(config).future);

      final storage =
          container.read(storageNotifierProvider.notifier)
              as PurplebaseStorageNotifier;

      final signer = DummySigner(container.read(refProvider));
      await signer.signIn();
      final note = await PartialNote('lifecycle test').signWith(signer);
      await storage.save({note});

      final result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(result, hasLength(1));

      await storage.clear();
      storage.dispose();
      storage.obliterate();
      container.dispose();
    });

    test('query returns empty on fresh database', () async {
      final container = await createStorageTestContainer();

      final result = await container.storage.query(
        RequestFilter(kinds: {1}).toRequest(),
      );
      expect(result, isEmpty);

      await container.tearDown();
    });

    test('clear empties the database', () async {
      final container = await createStorageTestContainer();
      final storage = container.storage;
      final signer = DummySigner(container.ref);
      await signer.signIn();

      final note = await PartialNote('clear test').signWith(signer);
      await storage.save({note});

      await storage.clear();

      final result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(result, isEmpty);

      await container.tearDown();
    });
  });
}
