// Re-export from new location for backwards compatibility
export 'helpers/helpers.dart';

import 'dart:async';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'helpers/helpers.dart';

/// Helper for testing state notifier emissions
class StateNotifierTester {
  final StateNotifier notifier;

  final _disposeFns = <void Function()>[];
  var completer = Completer<dynamic>();
  var initial = true;

  StateNotifierTester(this.notifier, {bool fireImmediately = false}) {
    final dispose = notifier.addListener((state) {
      if (fireImmediately && initial) {
        Future.microtask(() {
          completer.complete(state);
          completer = Completer();
          initial = false;
        });
      } else {
        completer.complete(state);
        completer = Completer();
      }
    }, fireImmediately: fireImmediately);
    _disposeFns.add(dispose);
  }

  Future<dynamic> expect(Matcher m) async {
    return expectLater(completer.future, completion(m));
  }

  void dispose() {
    for (final fn in _disposeFns) {
      fn.call();
    }
  }
}

/// Extension on ProviderContainer for creating state notifier testers
extension ProviderContainerTestExt on ProviderContainer {
  StateNotifierTester testerFor(
    AutoDisposeStateNotifierProvider provider, {
    bool fireImmediately = false,
  }) {
    // Keep the provider alive during the test
    listen(provider, (_, __) {}).read();

    return StateNotifierTester(
      read(provider.notifier),
      fireImmediately: fireImmediately,
    );
  }
}

/// Create a standard test configuration for storage tests
StorageConfiguration testConfig(
  String relayUrl, {
  bool skipVerification = true,
  Duration responseTimeout = const Duration(seconds: 5),
  Duration streamingBufferDuration = const Duration(milliseconds: 100),
}) {
  return StorageConfiguration(
    skipVerification: skipVerification,
    defaultRelays: {
      'test': {relayUrl},
    },
    defaultQuerySource: const LocalAndRemoteSource(
      relays: 'test',
      stream: false,
    ),
    responseTimeout: responseTimeout,
    streamingBufferDuration: streamingBufferDuration,
  );
}

/// Creates a configured ProviderContainer for storage-level testing.
///
/// This is for tests that need full storage integration (SQLite),
/// not just pool-level testing.
Future<ProviderContainer> createStorageTestContainer({
  StorageConfiguration? config,
}) async {
  final container = ProviderContainer(
    overrides: [
      storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
    ],
  );

  final storageConfig =
      config ??
      StorageConfiguration(
        skipVerification: true,
        defaultRelays: {
          'test': {'wss://test.relay'},
        },
        defaultQuerySource: LocalSource(),
      );

  await container.read(initializationProvider(storageConfig).future);

  return container;
}

/// Extension on ProviderContainer for storage test operations
extension StorageTestContainerExt on ProviderContainer {
  /// Get the storage notifier
  PurplebaseStorageNotifier get storage =>
      read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;

  /// Get ref for model construction
  Ref get ref => read(refProvider);

  /// Clear storage and dispose container
  Future<void> tearDown() async {
    await storage.clear();
    storage.dispose();
    storage.obliterate();
    dispose();
  }
}
