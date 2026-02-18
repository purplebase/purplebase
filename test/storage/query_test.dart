import 'package:models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/test_container.dart';

void main() {
  late ProviderContainer container;
  late StorageNotifier storage;
  late DummySigner signer;

  late Note testNote1, testNote2, testNote3;

  setUpAll(() async {
    container = await createStorageTestContainer();
    storage = container.storage;
    signer = DummySigner(container.ref);
    await signer.signIn();

    testNote1 = await PartialNote(
      'Note 1 with #bitcoin tag',
      tags: {'bitcoin', 'test'},
    ).signWith(signer);

    testNote2 = await PartialNote(
      'Note 2 with #lightning tag',
      tags: {'lightning', 'test'},
    ).signWith(signer);

    testNote3 = await PartialNote('Note 3 no tags').signWith(signer);
  });

  setUp(() async {
    await storage.clear();
    await storage.save({testNote1, testNote2, testNote3});
  });

  tearDownAll(() async {
    await container.tearDown();
  });

  group('Query by filter combinations', () {
    test('filter by kind + author', () async {
      final result = await storage.query(
        RequestFilter(kinds: {1}, authors: {signer.pubkey}).toRequest(),
      );
      expect(result, hasLength(3));
    });

    test('filter by tag with multiple values', () async {
      final result = await storage.query(
        RequestFilter(
          tags: {
            '#t': {'bitcoin', 'lightning'},
          },
        ).toRequest(),
      );
      expect(result, hasLength(2));
    });

    test('filter by time range covers all events', () async {
      final now = DateTime.now();
      final result = await storage.query(
        RequestFilter(
          since: now.subtract(Duration(hours: 1)),
          until: now.add(Duration(hours: 1)),
        ).toRequest(),
      );
      expect(result, hasLength(3));
    });

    test('filter with limit returns correct count', () async {
      final result = await storage.query(
        RequestFilter(kinds: {1}, limit: 1).toRequest(),
      );
      expect(result, hasLength(1));
    });

    test('query returns empty for non-matching filters', () async {
      final result = await storage.query(
        RequestFilter(kinds: {9999}).toRequest(),
      );
      expect(result, isEmpty);
    });

    test('handles massive query by tag efficiently', () async {
      const amount = 500;
      final futures = List.generate(
        amount,
        (i) => PartialNote('note $i', tags: {'perf_$i'}).signWith(signer),
      );
      final notes = await Future.wait(futures);
      await storage.save(notes.toSet());

      for (final i in [0, amount ~/ 2, amount - 1]) {
        final result = await storage.query(
          RequestFilter<Note>(
            tags: {
              '#t': {'perf_$i'}
            },
          ).toRequest(),
        );
        expect(result, hasLength(1));
        expect(result.first.content, contains('note $i'));
      }
    });
  });
}
