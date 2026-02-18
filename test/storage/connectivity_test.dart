import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/test_container.dart';

void main() {
  late ProviderContainer container;
  late PurplebaseStorageNotifier storage;

  setUpAll(() async {
    container = await createStorageTestContainer();
    storage = container.storage;
  });

  tearDownAll(() async {
    await container.tearDown();
  });

  group('Connectivity awareness', () {
    test('connect does not throw when initialized', () {
      expect(() => storage.connect(), returnsNormally);
    });

    test('disconnect does not throw when initialized', () {
      expect(() => storage.disconnect(), returnsNormally);
    });

    test('connect before initialize is a no-op', () {
      final uninitContainer = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );
      final uninitStorage = uninitContainer
          .read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;

      expect(() => uninitStorage.connect(), returnsNormally);
      uninitContainer.dispose();
    });
  });
}
