import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for closeSubscriptions functionality through the isolate.
///
/// These tests verify:
/// - Closing subscriptions via the storage API
/// - Relay URL resolution (named relays, sets, single URLs)
/// - Proper cleanup across the isolate boundary
void main() {
  Process? relayProcess;
  final relayPort = TestPorts.isolateRemote + 2; // Use unique port
  final relayUrl = 'ws://127.0.0.1:$relayPort';

  late ProviderContainer container;
  late PurplebaseStorageNotifier storage;
  late Bip340PrivateKeySigner signer;

  setUpAll(() async {
    relayProcess = await Process.start('test/support/test-relay', [
      '-port',
      relayPort.toString(),
    ]);

    relayProcess!.stdout.transform(utf8.decoder).listen((_) {});
    relayProcess!.stderr.transform(utf8.decoder).listen((_) {});

    await Future.delayed(Duration(milliseconds: 500));

    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    final config = StorageConfiguration(
      skipVerification: true,
      defaultRelays: {
        'primary': {relayUrl},
        'secondary': {'ws://localhost:65533'}, // Non-existent for testing
      },
      defaultQuerySource: LocalAndRemoteSource(
        relays: 'primary',
        stream: false,
      ),
      responseTimeout: Duration(seconds: 2),
    );

    await container.read(initializationProvider(config).future);
    storage =
        container.read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;

    signer = Bip340PrivateKeySigner(
      Utils.generateRandomHex64(),
      container.read(refProvider),
    );
    await signer.signIn();
  });

  tearDownAll(() async {
    storage.dispose();
    container.dispose();
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  setUp(() async {
    // Clear any existing subscriptions by clearing relay state
    relayProcess?.kill(ProcessSignal.sigusr1);
    await Future.delayed(Duration(milliseconds: 50));
  });

  group('closeSubscriptions', () {
    test('closes streaming subscriptions by relay URL set', () async {
      // Start a streaming subscription
      final req = RequestFilter(kinds: {1}).toRequest();

      // Start streaming query (doesn't block)
      storage.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      // Wait for subscription to be active
      await Future.delayed(Duration(milliseconds: 200));

      // Verify subscription exists in pool state
      final poolState = container.read(poolStateProvider);
      expect(poolState?.subscriptions.containsKey(req.subscriptionId), isTrue);

      // Close subscriptions to the relay
      await storage.closeSubscriptions(relays: {relayUrl});

      // Wait for state update
      await Future.delayed(Duration(milliseconds: 100));

      // Verify subscription was closed
      final updatedPoolState = container.read(poolStateProvider);
      expect(
        updatedPoolState?.subscriptions.containsKey(req.subscriptionId),
        isFalse,
      );
    });

    test('closes subscriptions by named relay', () async {
      final req = RequestFilter(kinds: {1}).toRequest();

      storage.query(req, source: RemoteSource(relays: 'primary', stream: true));

      await Future.delayed(Duration(milliseconds: 200));

      final poolState = container.read(poolStateProvider);
      expect(poolState?.subscriptions.containsKey(req.subscriptionId), isTrue);

      // Close using named relay
      await storage.closeSubscriptions(relays: 'primary');

      await Future.delayed(Duration(milliseconds: 100));

      final updatedPoolState = container.read(poolStateProvider);
      expect(
        updatedPoolState?.subscriptions.containsKey(req.subscriptionId),
        isFalse,
      );
    });

    test('handles empty relay set gracefully', () async {
      // Should not throw
      await storage.closeSubscriptions(relays: <String>{});
    });

    test('handles non-existent named relay gracefully', () async {
      // Should not throw when relay name doesn't exist
      await storage.closeSubscriptions(relays: 'non_existent_relay');
    });

    test('closes multiple subscriptions to same relay', () async {
      final req1 = RequestFilter(kinds: {1}).toRequest();
      final req2 = RequestFilter(kinds: {30000}).toRequest();

      storage.query(req1, source: RemoteSource(relays: {relayUrl}, stream: true));
      storage.query(req2, source: RemoteSource(relays: {relayUrl}, stream: true));

      await Future.delayed(Duration(milliseconds: 200));

      final poolState = container.read(poolStateProvider);
      expect(poolState?.subscriptions.containsKey(req1.subscriptionId), isTrue);
      expect(poolState?.subscriptions.containsKey(req2.subscriptionId), isTrue);

      await storage.closeSubscriptions(relays: {relayUrl});

      await Future.delayed(Duration(milliseconds: 100));

      final updatedPoolState = container.read(poolStateProvider);
      expect(
        updatedPoolState?.subscriptions.containsKey(req1.subscriptionId),
        isFalse,
      );
      expect(
        updatedPoolState?.subscriptions.containsKey(req2.subscriptionId),
        isFalse,
      );
    });

    test('does not affect subscriptions to other relays', () async {
      final req = RequestFilter(kinds: {1}).toRequest();

      storage.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      await Future.delayed(Duration(milliseconds: 200));

      final poolState = container.read(poolStateProvider);
      expect(poolState?.subscriptions.containsKey(req.subscriptionId), isTrue);

      // Close subscriptions to a different relay
      await storage.closeSubscriptions(relays: 'secondary');

      await Future.delayed(Duration(milliseconds: 100));

      // Original subscription should still exist
      final updatedPoolState = container.read(poolStateProvider);
      expect(
        updatedPoolState?.subscriptions.containsKey(req.subscriptionId),
        isTrue,
      );

      // Cleanup
      await storage.cancel(req);
    });

    test('is safe to call when not initialized', () async {
      // Create a fresh, uninitialized storage
      final tempContainer = ProviderContainer(
        overrides: [
          storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
        ],
      );

      final uninitStorage =
          tempContainer.read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;

      // Should not throw
      await uninitStorage.closeSubscriptions(relays: {relayUrl});

      tempContainer.dispose();
    });

    test('is idempotent - safe to call multiple times', () async {
      final req = RequestFilter(kinds: {1}).toRequest();

      storage.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      await Future.delayed(Duration(milliseconds: 200));

      // First close
      await storage.closeSubscriptions(relays: {relayUrl});

      await Future.delayed(Duration(milliseconds: 100));

      // Second close should be safe
      await storage.closeSubscriptions(relays: {relayUrl});

      // Third close should still be safe
      await storage.closeSubscriptions(relays: {relayUrl});
    });
  });

  group('closeSubscriptions relay resolution', () {
    test('resolves single string relay URL', () async {
      final req = RequestFilter(kinds: {1}).toRequest();

      storage.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      await Future.delayed(Duration(milliseconds: 200));

      // Pass as single string (should still work via resolveRelays)
      await storage.closeSubscriptions(relays: relayUrl);

      await Future.delayed(Duration(milliseconds: 100));

      final updatedPoolState = container.read(poolStateProvider);
      expect(
        updatedPoolState?.subscriptions.containsKey(req.subscriptionId),
        isFalse,
      );
    });

    test('resolves list of relay URLs', () async {
      final req = RequestFilter(kinds: {1}).toRequest();

      storage.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

      await Future.delayed(Duration(milliseconds: 200));

      // Pass as list
      await storage.closeSubscriptions(relays: [relayUrl]);

      await Future.delayed(Duration(milliseconds: 100));

      final updatedPoolState = container.read(poolStateProvider);
      expect(
        updatedPoolState?.subscriptions.containsKey(req.subscriptionId),
        isFalse,
      );
    });
  });
}
