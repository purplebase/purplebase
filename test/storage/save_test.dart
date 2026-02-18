import 'package:models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/test_container.dart';

void main() {
  late ProviderContainer container;
  late StorageNotifier storage;
  late DummySigner signer;

  setUpAll(() async {
    container = await createStorageTestContainer();
    storage = container.storage;
    signer = DummySigner(container.ref);
    await signer.signIn();
  });

  setUp(() async {
    await storage.clear();
  });

  tearDownAll(() async {
    await container.tearDown();
  });

  group('Save operations', () {
    test('saves and retrieves a single event', () async {
      final note = await PartialNote('save test').signWith(signer);
      final result = await storage.save({note});
      expect(result, isTrue);

      final q = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(q, hasLength(1));
      expect(q.first.id, note.id);
    });

    test('saves empty set without error', () async {
      final result = await storage.save(<Model<dynamic>>{});
      expect(result, isTrue);
    });

    test('handles duplicate saves gracefully', () async {
      final note = await PartialNote('dupe').signWith(signer);
      await storage.save({note});
      final result = await storage.save({note});
      expect(result, isTrue);

      final q = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
      );
      expect(q, hasLength(1));
    });

    test('saves events of different kinds', () async {
      final note = await PartialNote('a note').signWith(signer);
      final dm = await PartialDirectMessage(
        content: 'a dm',
        receiver: Utils.generateRandomHex64(),
      ).signWith(signer);

      await storage.save({note, dm});

      final notes = await storage.query(
        RequestFilter(kinds: {1}).toRequest(),
      );
      expect(notes, hasLength(1));

      final dms = await storage.query(
        RequestFilter(kinds: {4}).toRequest(),
      );
      expect(dms, hasLength(1));
    });

    test('preserves tags through save/query cycle', () async {
      final note = await PartialNote(
        'tagged',
        tags: {'hello', 'world'},
      ).signWith(signer);

      await storage.save({note});

      final result = await storage.query(
        RequestFilter(
          tags: {
            '#t': {'hello'},
          },
        ).toRequest(),
      );
      expect(result, hasLength(1));
      expect(result.first.id, note.id);
    });
  });
}
