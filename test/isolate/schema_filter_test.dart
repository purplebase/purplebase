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

  group('Schema filter in queries', () {
    test('schemaFilter filters events after decoding', () async {
      final note1 = await PartialNote('match this').signWith(signer);
      final note2 = await PartialNote('skip this').signWith(signer);
      await storage.save({note1, note2});

      final result = await storage.query(
        RequestFilter(
          kinds: {1},
          schemaFilter: (event) =>
              (event['content'] as String).contains('match'),
        ).toRequest(),
      );

      expect(result, hasLength(1));
      expect(result.first.event.content, 'match this');
    });

    test('schemaFilter with empty result', () async {
      final note = await PartialNote('no match here').signWith(signer);
      await storage.save({note});

      final result = await storage.query(
        RequestFilter(
          kinds: {1},
          schemaFilter: (event) =>
              (event['content'] as String).contains('xyz'),
        ).toRequest(),
      );

      expect(result, isEmpty);
    });
  });
}
