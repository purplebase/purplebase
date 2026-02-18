import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

/// Multi-relay integration test:
/// Two separate test-relay instances, queries spanning both.
void main() {
  Process? relay1Process, relay2Process;
  final relay1Port = TestPorts.integration;
  final relay2Port = TestPorts.integration + 1;
  final relay1Url = 'ws://127.0.0.1:$relay1Port';
  final relay2Url = 'ws://127.0.0.1:$relay2Port';

  late ProviderContainer container;
  late StorageNotifier storage;
  late Bip340PrivateKeySigner signer;

  setUpAll(() async {
    relay1Process = await Process.start(
        'test/support/test-relay', ['-port', relay1Port.toString()]);
    relay2Process = await Process.start(
        'test/support/test-relay', ['-port', relay2Port.toString()]);

    for (final p in [relay1Process!, relay2Process!]) {
      p.stdout.transform(utf8.decoder).listen((_) {});
      p.stderr.transform(utf8.decoder).listen((_) {});
    }
    await Future.delayed(Duration(milliseconds: 500));

    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    final config = StorageConfiguration(
      skipVerification: true,
      defaultRelays: {
        'multi': {relay1Url, relay2Url},
      },
      defaultQuerySource:
          LocalAndRemoteSource(relays: 'multi', stream: false),
      responseTimeout: Duration(seconds: 5),
    );

    await container.read(initializationProvider(config).future);
    storage = container.read(storageNotifierProvider.notifier);

    signer = Bip340PrivateKeySigner(
        TestKeys.privateKey, container.read(refProvider));
    await signer.signIn();
  });

  tearDownAll(() async {
    storage.dispose();
    container.dispose();
    relay1Process?.kill();
    relay2Process?.kill();
    await relay1Process?.exitCode;
    await relay2Process?.exitCode;
  });

  group('Multi-relay', () {
    test('publish to one relay, query from both', () async {
      final note = await PartialNote(
        'multi relay test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(signer);

      // Publish to relay1 only
      await storage.publish(
        {note},
        source: RemoteSource(relays: {relay1Url}),
      );

      // Query from relay1 should find it
      final result1 = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: RemoteSource(relays: {relay1Url}, stream: false),
      );
      expect(result1, isNotEmpty);
      expect(result1.first.id, note.id);

      // Query from relay2 should NOT find it (it was only published to relay1)
      final result2 = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: RemoteSource(relays: {relay2Url}, stream: false),
      );
      expect(result2, isEmpty);
    });

    test('publish to both relays succeeds', () async {
      final note = await PartialNote(
        'both relays ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(signer);

      final response = await storage.publish(
        {note},
        source: RemoteSource(relays: {relay1Url, relay2Url}),
      );

      expect(response.results, isNotEmpty);

      // Both relays should have it
      final r1 = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: RemoteSource(relays: {relay1Url}, stream: false),
      );
      final r2 = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: RemoteSource(relays: {relay2Url}, stream: false),
      );
      expect(r1, isNotEmpty);
      expect(r2, isNotEmpty);
    });
  });
}
