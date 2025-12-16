import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Tests for storage lifecycle methods (connect, disconnect, etc.)
void main() {
  group('Storage Lifecycle', () {
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
        defaultRelays: {
          'test': {'wss://relay.test.com'},
        },
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;
    });

    tearDown(() {
      storage.dispose();
      container.dispose();
    });

    test('connect should be callable when initialized', () {
      expect(storage.isInitialized, isTrue);
      
      // Should not throw
      expect(
        () => storage.connect(),
        returnsNormally,
        reason: 'connect should be safe to call',
      );
    });

    test('connect should not throw when called before initialization', () {
      final uninitializedContainer = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );
      
      final uninitializedStorage = 
          uninitializedContainer.read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;
      
      // Should not throw, just return early
      expect(
        () => uninitializedStorage.connect(),
        returnsNormally,
        reason: 'Should handle being called before initialization',
      );
      
      uninitializedContainer.dispose();
    });

    test('connect can be called multiple times', () {
      // Should be idempotent
      storage.connect();
      storage.connect();
      storage.connect();
      
      // No errors, storage still functional
      expect(storage.isInitialized, isTrue);
    });

    test('disconnect should be callable when initialized', () {
      expect(storage.isInitialized, isTrue);
      
      // Should not throw
      expect(
        () => storage.disconnect(),
        returnsNormally,
        reason: 'disconnect should be safe to call',
      );
    });

    test('disconnect should not throw when called before initialization', () {
      final uninitializedContainer = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );
      
      final uninitializedStorage = 
          uninitializedContainer.read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;
      
      // Should not throw, just return early
      expect(
        () => uninitializedStorage.disconnect(),
        returnsNormally,
        reason: 'Should handle being called before initialization',
      );
      
      uninitializedContainer.dispose();
    });
  });
}

