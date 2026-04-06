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
  final relayPort = TestPorts.isolateRemote + 1;
  final relayUrl = 'ws://127.0.0.1:$relayPort';

  late ProviderContainer container;
  late StorageNotifier storage;
  late Bip340PrivateKeySigner signer;
  late Note testNote1, testNote2;

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
      responseTimeout: Duration(milliseconds: 200),
    );

    await container.read(initializationProvider(config).future);
    storage = container.read(storageNotifierProvider.notifier);

    signer = Bip340PrivateKeySigner(
        Utils.generateRandomHex64(), container.read(refProvider));
    await signer.signIn();

    testNote1 = await PartialNote(
      'Test note for remote query ${DateTime.now().millisecondsSinceEpoch}',
      tags: {'test', 'remote'},
    ).signWith(signer);

    testNote2 = await PartialNote(
      'Second test note ${DateTime.now().millisecondsSinceEpoch}',
      tags: {'test', 'batch'},
    ).signWith(signer);

    await storage.publish(
        {testNote1, testNote2}, relays: {relayUrl});
  });

  tearDownAll(() async {
    storage.dispose();
    container.dispose();
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  group('Query by filters', () {
    test('queries events by ID from relay', () async {
      final result = await storage.query(
        RequestFilter(ids: {testNote1.id}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );

      expect(result, isNotEmpty);
      final found = result.where((e) => e.id == testNote1.id).firstOrNull;
      expect(found, isNotNull);
      expect(found!.event.content, contains('Test note for remote query'));
    });

    test('queries events by kind from relay', () async {
      final result = await storage.query(
        RequestFilter(kinds: {1}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );
      expect(result, isNotEmpty);
      expect(result.every((e) => e.event.kind == 1), isTrue);
    });

    test('queries events by author from relay', () async {
      final result = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );
      expect(result, isNotEmpty);
      expect(result.every((e) => e.event.pubkey == signer.pubkey), isTrue);
    });
  });

  group('Local persistence', () {
    test('persists remote query results to local storage', () async {
      final uniqueNote = await PartialNote(
        'Local cache test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(signer);

      await storage.publish(
          {uniqueNote}, relays: {relayUrl});

      final remoteResult = await storage.query(
        RequestFilter(ids: {uniqueNote.id}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );
      expect(remoteResult, isNotEmpty);

      final localResult = await storage.query(
        RequestFilter(ids: {uniqueNote.id}).toRequest(),
        source: LocalSource(),
      );
      expect(localResult, isNotEmpty);
      expect(localResult.first.id, equals(uniqueNote.id));
    });
  });
}
