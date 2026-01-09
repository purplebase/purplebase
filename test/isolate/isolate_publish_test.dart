import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for remote publish operations via isolate.
void main() {
  Process? relayProcess;
  final relayPort = TestPorts.isolateRemote;
  final relayUrl = TestRelays.isolateRemote;

  late ProviderContainer container;
  late StorageNotifier storage;
  late Bip340PrivateKeySigner signer;
  late Note testNote1, testNote2;

  setUpAll(() async {
    // Start test relay
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
        'offline': {TestRelays.offline},
      },
      defaultQuerySource: LocalAndRemoteSource(
        relays: 'primary',
        stream: false,
      ),
      responseTimeout: Duration(seconds: 5),
    );

    await container.read(initializationProvider(config).future);
    storage = container.read(storageNotifierProvider.notifier);

    signer = Bip340PrivateKeySigner(
      Utils.generateRandomHex64(),
      container.read(refProvider),
    );
    await signer.signIn();

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    testNote1 = await PartialNote(
      'Test note for remote operations $timestamp',
      tags: {'test', 'remote'},
    ).signWith(signer);

    testNote2 = await PartialNote(
      'Second test note for batch operations $timestamp',
      tags: {'test', 'batch'},
    ).signWith(signer);
  });

  tearDownAll(() async {
    try {
      storage.dispose();
      container.dispose();
    } catch (_) {}
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  group('Single event publish', () {
    test('publishes single event to relay', () async {
      final response = await storage.publish(
        {testNote1},
        source: RemoteSource(relays: 'primary'),
      );

      expect(response, isA<PublishResponse>());
      expect(response.results, isNotEmpty);
      expect(response.results.containsKey(testNote1.id), isTrue);

      final eventStates = response.results[testNote1.id]!;
      expect(eventStates, isNotEmpty);
      expect(eventStates.every((state) => state.accepted), isTrue);
    });

    test('handles empty event set', () async {
      final response = await storage.publish(
        <Model<dynamic>>{},
        source: RemoteSource(relays: 'primary'),
      );

      expect(response, isA<PublishResponse>());
      expect(response.results, isEmpty);
    });
  });

  group('Multiple event publish', () {
    test('publishes multiple events to relay', () async {
      final response = await storage.publish(
        {testNote1, testNote2},
        source: RemoteSource(relays: 'primary'),
      );

      expect(response, isA<PublishResponse>());
      expect(response.results, isNotEmpty);
      expect(response.results.containsKey(testNote1.id), isTrue);
      expect(response.results.containsKey(testNote2.id), isTrue);

      final note1States = response.results[testNote1.id]!;
      final note2States = response.results[testNote2.id]!;
      expect(note1States.every((state) => state.accepted), isTrue);
      expect(note2States.every((state) => state.accepted), isTrue);
    });
  });

  group('Error handling', () {
    test('handles offline relay gracefully', () async {
      final response = await storage.publish(
        {testNote1},
        source: RemoteSource(relays: 'offline'),
      );

      expect(response, isA<PublishResponse>());
      expect(response.results, isNotEmpty);
      expect(response.results.containsKey(testNote1.id), isTrue);

      final eventStates = response.results[testNote1.id]!;
      expect(eventStates, isNotEmpty);
      expect(eventStates.every((state) => !state.accepted), isTrue);
    });

    test('handles large events', () async {
      final largeContent = 'Large content: ${'x' * 50000}';
      final largeNote = await PartialNote(largeContent).signWith(signer);

      final response = await storage.publish(
        {largeNote},
        source: RemoteSource(relays: 'primary'),
      );

      expect(response, isA<PublishResponse>());
      expect(response.results, isNotEmpty);
      expect(response.results.containsKey(largeNote.id), isTrue);

      final eventStates = response.results[largeNote.id]!;
      expect(eventStates.every((state) => state.accepted), isTrue);
    });
  });
}

