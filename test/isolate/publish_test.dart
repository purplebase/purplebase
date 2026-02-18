import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  Process? relayProcess;
  final relayPort = TestPorts.isolatePublish;
  final relayUrl = 'ws://127.0.0.1:$relayPort';

  late ProviderContainer container;
  late StorageNotifier storage;
  late Bip340PrivateKeySigner signer;

  setUpAll(() async {
    relayProcess = await Process.start(
        'test/support/test-relay', ['-port', relayPort.toString()]);
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
      },
      defaultQuerySource:
          LocalAndRemoteSource(relays: 'primary', stream: false),
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
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  group('Publish via storage', () {
    test('publishes event and relay accepts it', () async {
      final note = await PartialNote(
        'publish test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(signer);

      final response = await storage.publish(
        {note},
        source: RemoteSource(relays: {relayUrl}),
      );

      expect(response.results, isNotEmpty);
      expect(response.results[note.id]!.first.accepted, isTrue);

      // Verify the relay has the event by querying it back
      final remote = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );
      expect(remote, isNotEmpty);
      expect(remote.first.id, equals(note.id));
    });

    test('publishes multiple events', () async {
      final notes = await Future.wait([
        PartialNote('pub test 1').signWith(signer),
        PartialNote('pub test 2').signWith(signer),
      ]);

      final response = await storage.publish(
        notes.toSet(),
        source: RemoteSource(relays: {relayUrl}),
      );

      expect(response.results.length, equals(2));
      for (final note in notes) {
        expect(response.results.containsKey(note.id), isTrue);
      }
    });
  });
}
