import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

/// Full-stack integration test:
/// Storage → Isolate → Pool → test-relay → back.
void main() {
  Process? relayProcess;
  final relayPort = TestPorts.storageFull;
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

  group('Full stack: publish → query remote → query local', () {
    test('published event is queryable from relay and persists locally',
        () async {
      final note = await PartialNote(
        'full stack test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(signer);

      // Publish through storage layer
      final response = await storage.publish(
        {note},
        relays: {relayUrl},
      );
      expect(response.results, isNotEmpty);
      expect(response.results[note.id]!.first.accepted, isTrue);

      // Query from relay
      final remoteResult = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );
      expect(remoteResult, isNotEmpty);
      expect(remoteResult.first.id, note.id);
      expect(remoteResult.first.event.content, contains('full stack test'));

      // Query from local — should be persisted by the remote query
      final localResult = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: LocalSource(),
      );
      expect(localResult, isNotEmpty);
      expect(localResult.first.id, note.id);
    });

    test('save locally → query locally', () async {
      final note = await PartialNote('local round trip').signWith(signer);
      await storage.save({note});

      final result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
      expect(result.first.event.content, 'local round trip');
    });

    test('multiple events survive full cycle', () async {
      final notes = await Future.wait([
        PartialNote('full 1').signWith(signer),
        PartialNote('full 2').signWith(signer),
        PartialNote('full 3').signWith(signer),
      ]);

      await storage.publish(
        notes.toSet(),
        relays: {relayUrl},
      );

      final result = await storage.query(
        RequestFilter(
          ids: notes.map((n) => n.id).toSet(),
        ).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );
      expect(result.length, equals(3));
    });
  });
}
