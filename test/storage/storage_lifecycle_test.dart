import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Tests for storage lifecycle methods.
///
/// These tests verify purplebase-specific lifecycle behavior:
/// - connect/disconnect methods on PurplebaseStorageNotifier
/// - Behavior before/after initialization
void main() {
  group('Storage lifecycle', () {
    late ProviderContainer container;
    late PurplebaseStorageNotifier storage;

    setUp(() async {
      container = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );

      final config = StorageConfiguration(
        skipVerification: true,
        defaultRelays: {'test': {'wss://relay.test.com'}},
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier)
          as PurplebaseStorageNotifier;
    });

    tearDown(() {
      storage.dispose();
      container.dispose();
    });

    test('connect is safe when initialized', () {
      expect(storage.isInitialized, isTrue);

      expect(
        () => storage.connect(),
        returnsNormally,
      );
    });

    test('connect is safe before initialization', () {
      final uninitContainer = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );

      final uninitStorage = uninitContainer.read(storageNotifierProvider.notifier)
          as PurplebaseStorageNotifier;

      expect(
        () => uninitStorage.connect(),
        returnsNormally,
      );

      uninitContainer.dispose();
    });

    test('connect is idempotent', () {
      storage.connect();
      storage.connect();
      storage.connect();

      expect(storage.isInitialized, isTrue);
    });

    test('disconnect is safe when initialized', () {
      expect(storage.isInitialized, isTrue);

      expect(
        () => storage.disconnect(),
        returnsNormally,
      );
    });

    test('disconnect is safe before initialization', () {
      final uninitContainer = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );

      final uninitStorage = uninitContainer.read(storageNotifierProvider.notifier)
          as PurplebaseStorageNotifier;

      expect(
        () => uninitStorage.disconnect(),
        returnsNormally,
      );

      uninitContainer.dispose();
    });
  });
}
