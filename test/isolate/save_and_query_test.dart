import 'package:models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/test_container.dart';

void main() {
  late ProviderContainer container;
  late StorageNotifier storage;
  late DummySigner signer;

  late Note testNote1, testNote2, testNote3;
  late DirectMessage testDM;
  late Set<Model<dynamic>> testEvents;

  setUpAll(() async {
    container = await createStorageTestContainer(
      config: StorageConfiguration(
        skipVerification: true,
        defaultRelays: {
          'test': {'wss://test1.com', 'wss://test2.com'},
        },
        defaultQuerySource: LocalSource(),
      ),
    );

    storage = container.storage;
    signer = DummySigner(container.ref);
    await signer.signIn();

    testNote1 = await PartialNote(
      'Test note 1 with #bitcoin and #nostr tags',
      tags: {'bitcoin', 'nostr', 'test'},
    ).signWith(signer);

    testNote2 = await PartialNote(
      'Test note 2 about #lightning network',
      tags: {'lightning', 'test'},
    ).signWith(signer);

    testNote3 = await PartialNote('Simple note without tags').signWith(signer);

    testDM = await PartialDirectMessage(
      content: 'Secret test message',
      receiver: Utils.generateRandomHex64(),
    ).signWith(signer);

    testEvents = {testNote1, testNote2, testNote3, testDM};
    await storage.save(testEvents);
  });

  setUp(() async {
    await storage.clear();
    await storage.save(testEvents);
  });

  tearDownAll(() async {
    await container.tearDown();
  });

  group('Save operations', () {
    test('saves single event', () async {
      final newNote = await PartialNote('New single note').signWith(signer);
      final result = await storage.save({newNote});
      expect(result, isTrue);

      final queryResult = await storage.query(
        RequestFilter(ids: {newNote.id}).toRequest(),
      );
      expect(queryResult, hasLength(1));
      expect(queryResult.first.id, equals(newNote.id));
    });

    test('saves multiple events in batch', () async {
      final notes = await Future.wait([
        PartialNote('Batch note 1').signWith(signer),
        PartialNote('Batch note 2').signWith(signer),
        PartialNote('Batch note 3').signWith(signer),
      ]);

      await storage.save(notes.toSet());

      final queryResult = await storage.query(
        RequestFilter(ids: notes.map((n) => n.id).toSet()).toRequest(),
      );
      expect(queryResult, hasLength(3));
    });

    test('handles duplicate events gracefully', () async {
      final result = await storage.save({testNote1});
      expect(result, isTrue);
    });

    test('handles large content', () async {
      final largeContent = 'x' * 100000;
      final largeNote = await PartialNote(largeContent).signWith(signer);
      await storage.save({largeNote});

      final queryResult = await storage.query(
        RequestFilter(ids: {largeNote.id}).toRequest(),
      );
      expect(queryResult.first.event.content, equals(largeContent));
    });

    test('handles special characters', () async {
      const specialContent = 'Test with émojis 🚀⚡️ and ünïcödé 中文';
      final specialNote = await PartialNote(specialContent).signWith(signer);
      await storage.save({specialNote});

      final queryResult = await storage.query(
        RequestFilter(ids: {specialNote.id}).toRequest(),
      );
      expect(queryResult.first.event.content, equals(specialContent));
    });
  });

  group('Query operations', () {
    test('queries by single ID', () async {
      final result = await storage.query(
        RequestFilter(ids: {testNote1.id}).toRequest(),
      );
      expect(result, hasLength(1));
      expect(result.first.id, equals(testNote1.id));
    });

    test('queries by multiple IDs', () async {
      final result = await storage.query(
        RequestFilter(ids: {testNote1.id, testNote2.id}).toRequest(),
      );
      expect(result, hasLength(2));
      expect(
          result.map((e) => e.id), containsAll([testNote1.id, testNote2.id]));
    });

    test('queries by kinds', () async {
      final result = await storage.query(
        RequestFilter(kinds: {1}).toRequest(),
      );
      expect(result, hasLength(3));
      expect(result.every((e) => e.event.kind == 1), isTrue);
    });

    test('queries by authors', () async {
      final result = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(result, hasLength(4));
      expect(result.every((e) => e.event.pubkey == signer.pubkey), isTrue);
    });

    test('queries by tags', () async {
      final result = await storage.query(
        RequestFilter(tags: {
          '#t': {'bitcoin'},
        }).toRequest(),
      );
      expect(result, hasLength(1));
      expect(result.first.id, equals(testNote1.id));
    });

    test('queries with limit', () async {
      final result = await storage.query(
        RequestFilter(kinds: {1}, limit: 2).toRequest(),
      );
      expect(result, hasLength(2));
    });

    test('returns empty for non-existent ID', () async {
      final result = await storage.query(
        RequestFilter(ids: {Utils.generateRandomHex64()}).toRequest(),
      );
      expect(result, isEmpty);
    });
  });

  group('Clear operations', () {
    test('clears all data from storage', () async {
      final beforeClear = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(beforeClear, hasLength(4));

      await storage.clear();

      final afterClear = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
      );
      expect(afterClear, isEmpty);
    });

    test('can still save after clearing', () async {
      await storage.clear();

      final newNote = await PartialNote('Post-clear note').signWith(signer);
      await storage.save({newNote});

      final queryResult = await storage.query(
        RequestFilter(ids: {newNote.id}).toRequest(),
      );
      expect(queryResult, hasLength(1));
    });
  });
}
