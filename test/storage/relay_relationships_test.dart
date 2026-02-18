import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/test_container.dart';

void main() {
  late ProviderContainer container;
  late PurplebaseStorageNotifier storage;
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

  group('Relay relationships ("seen on")', () {
    test('queryRelaysForEvent returns empty for unknown event', () {
      final relays = storage.queryRelaysForEvent('unknown_id');
      expect(relays, isEmpty);
    });

    test('queryRelaysForEvent returns empty for event with no relay tags',
        () async {
      final note = await PartialNote('no relay').signWith(signer);
      await storage.save({note});

      final relays = storage.queryRelaysForEvent(note.id);
      expect(relays, isEmpty);
    });
  });
}
