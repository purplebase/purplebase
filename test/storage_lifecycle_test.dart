import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Tests for storage lifecycle methods (ensureConnected, etc.)
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
        relayGroups: {
          'test': {'wss://relay.test.com'},
        },
        defaultRelayGroup: 'test',
      );

      await container.read(initializationProvider(config).future);
      storage = container.read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;
    });

    tearDown(() {
      storage.dispose();
      container.dispose();
    });

    test('ensureConnected should be callable when initialized', () {
      expect(storage.isInitialized, isTrue);
      
      // Should not throw
      expect(
        () => storage.ensureConnected(),
        returnsNormally,
        reason: 'ensureConnected should be safe to call',
      );
    });

    test('ensureConnected should not throw when called before initialization', () {
      final uninitializedContainer = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );
      
      final uninitializedStorage = 
          uninitializedContainer.read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;
      
      // Should not throw, just return early
      expect(
        () => uninitializedStorage.ensureConnected(),
        returnsNormally,
        reason: 'Should handle being called before initialization',
      );
      
      uninitializedContainer.dispose();
    });

    test('ensureConnected can be called multiple times', () {
      // Should be idempotent
      storage.ensureConnected();
      storage.ensureConnected();
      storage.ensureConnected();
      
      // No errors, storage still functional
      expect(storage.isInitialized, isTrue);
    });
  });
}

