import 'package:models/models.dart';
import 'package:purplebase/src/utils.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for purplebase-specific storage behavior.
///
/// These tests verify behavior specific to the real SQLite storage implementation
/// that differs from DummyStorageNotifier. For general query/filter tests,
/// see ../models/test/storage_test.dart.
///
/// Purplebase-specific tests:
/// - Replaceable event database ID generation
/// - Large-scale query performance
/// - Event encoding/decoding roundtrips
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

  tearDown(() async {
    await storage.clear();
  });

  tearDownAll(() async {
    await container.tearDown();
  });

  group('Replaceable event database IDs', () {
    test('generates unique database IDs for different d-tag values', () async {
      // This tests the fix for the bug where both events would get
      // database ID "30000:pubkey:d" instead of "30000:pubkey:a" and "30000:pubkey:b"
      await storage.clear();

      final eventA = {
        'id': Utils.generateRandomHex64(),
        'pubkey': signer.pubkey,
        'created_at': DateTime.now().toSeconds(),
        'kind': 30000, // Parameterized replaceable event
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

      final events = <Map<String, dynamic>>[eventA, eventB];
      final (encodedEvents, _) = events.encoded();
      final idsGenerated = encodedEvents.map((e) => e[':id']).toSet();

      expect(idsGenerated.length, equals(2));
      expect(idsGenerated, contains('30000:${signer.pubkey}:a'));
      expect(idsGenerated, contains('30000:${signer.pubkey}:b'));
    });
  });

  group('Large-scale queries', () {
    test('handles massive query by tag efficiently', () async {
      const amount = 3000;

      final futures = List.generate(
        amount,
        (i) => PartialNote('note $i', tags: {'test $i'}).signWith(signer),
      );
      final notes = await Future.wait(futures);

      await storage.save(notes.toSet());

      // Verify we can query each tag efficiently
      for (final i in [0, amount ~/ 2, amount - 1]) {
        final result = await storage.query(
          RequestFilter<Note>(
            tags: {
              '#t': {'test $i'},
            },
          ).toRequest(),
        );
        expect(result.first.content, contains('note $i'));
      }
    });
  });

  group('Event encoding roundtrip', () {
    test('preserves special characters through save/query cycle', () async {
      const specialContent = 'Test with émojis 🚀⚡️ and ünïcödé characters 中文';
      final specialNote = await PartialNote(specialContent).signWith(signer);

      await storage.save({specialNote});

      final result = await storage.query(
        RequestFilter(ids: {specialNote.id}).toRequest(),
      );

      expect(result.first.event.content, equals(specialContent));
    });

    test('preserves large content through save/query cycle', () async {
      final largeContent = 'x' * 100000; // 100KB content
      final largeNote = await PartialNote(largeContent).signWith(signer);

      await storage.save({largeNote});

      final result = await storage.query(
        RequestFilter(ids: {largeNote.id}).toRequest(),
      );

      expect(result.first.event.content, equals(largeContent));
    });
  });
}
