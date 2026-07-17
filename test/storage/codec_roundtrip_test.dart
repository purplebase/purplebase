import 'package:models/models.dart';
import 'package:purplebase/src/db/codec.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late ProviderContainer container;
  late StorageNotifier storage;
  late DummySigner signer;

  setUpAll(() async {
    container = await createStorageTestContainer(
      config: StorageConfiguration(
        keepSignatures: true,
        skipVerification: true,
        defaultRelays: {
          'test': {'wss://test.relay'},
        },
        defaultQuerySource: LocalSource(),
      ),
    );
    storage = container.storage;
    signer = DummySigner(container.ref);
    await signer.signIn();
  });

  tearDown(() async {
    await storage.clear();
  });

  tearDownAll(() async {
    await container.tearDown();
  });

  group('Event encoding roundtrip through storage', () {
    test('preserves special characters', () async {
      const specialContent = 'Test with émojis 🚀⚡️ and ünïcödé 中文';
      final specialNote = await PartialNote(specialContent).signWith(signer);
      await storage.save({specialNote});

      final result = await storage.query(
        RequestFilter(ids: {specialNote.id}).toRequest(),
      );
      expect(result.first.event.content, equals(specialContent));
    });

    test('preserves large content', () async {
      final largeContent = 'x' * 100000;
      final largeNote = await PartialNote(largeContent).signWith(signer);
      await storage.save({largeNote});

      final result = await storage.query(
        RequestFilter(ids: {largeNote.id}).toRequest(),
      );
      expect(result.first.event.content, equals(largeContent));
    });

    test('replaceable event IDs work correctly', () async {
      final eventA = {
        'id': Utils.generateRandomHex64(),
        'pubkey': signer.pubkey,
        'created_at': DateTime.now().toSeconds(),
        'kind': 30000,
        'content': 'Data A',
        'tags': [
          ['d', 'a'],
        ],
        'sig': 'test_sig',
      };

      final eventB = {
        'id': Utils.generateRandomHex64(),
        'pubkey': signer.pubkey,
        'created_at': DateTime.now().toSeconds(),
        'kind': 30000,
        'content': 'Data B',
        'tags': [
          ['d', 'b'],
        ],
        'sig': 'test_sig',
      };

      // Verify different storage IDs
      final (encodedEvents, _) = EventCodec.encode([eventA, eventB]);
      final ids = encodedEvents.map((e) => e[':id']).toSet();

      expect(ids.length, equals(2));
      expect(ids, contains('30000:${signer.pubkey}:a'));
      expect(ids, contains('30000:${signer.pubkey}:b'));
    });

    test('preserves signed parameterized replaceable event IDs', () async {
      final signingKey = Bip340PrivateKeySigner(
        TestKeys.privateKey,
        container.read(refProvider),
      );
      await signingKey.signIn(setAsActive: false);
      final draft = await PartialCustomData(
        identifier: 'zapstore-device-state',
        content: 'encrypted device state',
      ).signWith(signingKey);
      await storage.save({draft});

      final result = await storage.query(
        RequestFilter<CustomData>(
          tags: {
            '#d': {'zapstore-device-state'},
          },
        ).toRequest(),
      );

      expect(result, hasLength(1));
      expect(result.single.id, draft.id);
      expect(DartVerifier().verify(result.single.toMap()), isTrue);
    });
  });
}
