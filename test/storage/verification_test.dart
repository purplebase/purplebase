import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/db.dart';
import 'package:purplebase/src/utils.dart' as utils;
import 'package:riverpod/riverpod.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for event signature verification.
///
/// These tests are purplebase-specific because they test the real signature
/// verification against SQLite storage, not DummyStorageNotifier.
///
/// Note: The current verifier only checks that the signature is valid for the
/// given pubkey and id. It does NOT verify that the id is the correct hash of
/// the event data.
void main() {
  late ProviderContainer container;
  late Database db;
  late StorageConfiguration config;
  late Verifier verifier;
  late Bip340PrivateKeySigner signer;

  setUpAll(() async {
    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    // IMPORTANT: skipVerification is FALSE - this enables signature checking
    config = StorageConfiguration(
      skipVerification: false,
      defaultRelays: {'test': {'wss://test.com'}},
      defaultQuerySource: LocalSource(),
    );

    await container.read(initializationProvider(config).future);
    verifier = container.read(verifierProvider);

    signer = Bip340PrivateKeySigner(
      Utils.generateRandomHex64(),
      container.read(refProvider),
    );
    await signer.signIn();

    db = sqlite3.openInMemory();
    db.initialize();
  });

  setUp(() {
    db.initialize(clear: true);
  });

  tearDownAll(() {
    db.dispose();
    container.dispose();
  });

  Set<String> saveToDb(Set<Map<String, dynamic>> events) {
    return db.save(events, {}, config, verifier);
  }

  List<Map<String, dynamic>> queryFromDb(
    String sql,
    Map<String, dynamic> params,
  ) {
    final stmt = db.prepare(sql);
    try {
      return stmt.selectWith(StatementParameters.named(params)).decoded();
    } finally {
      stmt.dispose();
    }
  }

  group('Valid signatures', () {
    test('saves and queries valid signed event', () async {
      final note = await PartialNote('Valid signed note').signWith(signer);
      final eventMap = note.toMap();

      final savedIds = saveToDb({eventMap});
      expect(savedIds, contains(note.id));

      final results = queryFromDb(
        'SELECT * FROM events WHERE id = :id',
        {':id': note.id},
      );
      expect(results, hasLength(1));
    });

    test('saves multiple events and keeps only valid ones', () async {
      final validNote = await PartialNote('Valid event').signWith(signer);
      final validMap = validNote.toMap();

      final invalidNote = await PartialNote('Another event').signWith(signer);
      final invalidMap = invalidNote.toMap();
      // 128 char invalid signature
      invalidMap['sig'] = Utils.generateRandomHex64() + Utils.generateRandomHex64();

      final savedIds = saveToDb({validMap, invalidMap});

      expect(savedIds, hasLength(1));
      expect(savedIds, contains(validNote.id));
      expect(savedIds, isNot(contains(invalidNote.id)));
    });
  });

  group('Invalid signatures', () {
    test('rejects event with corrupted signature', () async {
      final note = await PartialNote('Test note').signWith(signer);
      final eventMap = note.toMap();

      // Corrupt the signature (change last character)
      final sig = eventMap['sig'] as String;
      eventMap['sig'] =
          sig.substring(0, sig.length - 1) + (sig[sig.length - 1] == '0' ? '1' : '0');

      final savedIds = saveToDb({eventMap});
      expect(savedIds, isEmpty);

      final results = queryFromDb(
        'SELECT * FROM events WHERE id = :id',
        {':id': note.id},
      );
      expect(results, isEmpty);
    });

    test('rejects event with mismatched pubkey', () async {
      final note = await PartialNote('Test note').signWith(signer);
      final eventMap = note.toMap();

      eventMap['pubkey'] = Utils.generateRandomHex64();

      final savedIds = saveToDb({eventMap});
      expect(savedIds, isEmpty);
    });

    test('rejects event with invalid id', () async {
      final note = await PartialNote('Test note').signWith(signer);
      final eventMap = note.toMap();
      final originalId = note.id;

      eventMap['id'] = Utils.generateRandomHex64();

      final savedIds = saveToDb({eventMap});
      expect(savedIds, isEmpty);

      final results = queryFromDb(
        'SELECT * FROM events WHERE id = :id',
        {':id': originalId},
      );
      expect(results, isEmpty);
    });

    test('rejects event with completely wrong signature', () async {
      final note = await PartialNote('Test').signWith(signer);
      final eventMap = note.toMap();
      eventMap['sig'] = '00' * 64;

      final savedIds = saveToDb({eventMap});
      expect(savedIds, isEmpty);
    });
  });

  group('Configuration', () {
    test('verification enabled config rejects bad events', () async {
      expect(config.skipVerification, isFalse);

      final note = await PartialNote('Test').signWith(signer);
      final eventMap = note.toMap();
      eventMap['sig'] = '00' * 64;

      final savedIds = saveToDb({eventMap});
      expect(savedIds, isEmpty);
    });

    test('skipVerification true config accepts any event', () async {
      final noVerifyConfig = StorageConfiguration(
        skipVerification: true,
        defaultRelays: {'test': {'wss://test.com'}},
      );

      final note = await PartialNote('Test').signWith(signer);
      final eventMap = note.toMap();
      eventMap['sig'] = 'invalid_signature';

      final savedIds = db.save({eventMap}, {}, noVerifyConfig, verifier);
      expect(savedIds, isNotEmpty);
    });
  });
}
