import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/db.dart';
import 'package:purplebase/src/utils.dart' as utils;
import 'package:riverpod/riverpod.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for event signature verification.
/// These tests use skipVerification: false to ensure invalid events are rejected.
/// 
/// Since storage.save() takes Model objects, we test verification at the db layer
/// directly with raw maps to properly test tampered events.
///
/// NOTE: The current verifier only checks that the signature is valid for the
/// given pubkey and id. It does NOT verify that the id is the correct hash of
/// the event data. Therefore, tampering with content/kind/created_at while
/// keeping the same id will NOT be detected.
Future<void> main() async {
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
      defaultRelays: {
        'test': {'wss://test.com'},
      },
      defaultQuerySource: LocalSource(),
    );

    await container.read(initializationProvider(config).future);
    verifier = container.read(verifierProvider);

    signer = Bip340PrivateKeySigner(
      Utils.generateRandomHex64(),
      container.read(refProvider),
    );
    await signer.signIn();

    // Create in-memory database for testing
    db = sqlite3.openInMemory();
    db.initialize();
  });

  setUp(() {
    // Clear and reinitialize database before each test
    db.initialize(clear: true);
  });

  tearDownAll(() {
    db.dispose();
    container.dispose();
  });

  /// Helper to save events directly to db and return saved IDs
  Set<String> saveToDb(Set<Map<String, dynamic>> events) {
    return db.save(events, {}, config, verifier);
  }

  /// Helper to query events from db
  List<Map<String, dynamic>> queryFromDb(String sql, Map<String, dynamic> params) {
    final stmt = db.prepare(sql);
    try {
      return stmt.selectWith(StatementParameters.named(params)).decoded();
    } finally {
      stmt.dispose();
    }
  }

  group('Signature Verification', () {
    test('should save and query valid signed event', () async {
      // Create a properly signed event
      final note = await PartialNote('Valid signed note').signWith(signer);
      final eventMap = note.toMap();

      // Save should succeed and return the ID
      final savedIds = saveToDb({eventMap});
      expect(savedIds, contains(note.id), reason: 'Valid event should be saved');

      // Query should return the event
      final results = queryFromDb(
        'SELECT * FROM events WHERE id = :id',
        {':id': note.id},
      );
      expect(results, hasLength(1), reason: 'Should find the valid event');
    });

    test('should reject event with corrupted signature', () async {
      // Create a properly signed event first
      final note = await PartialNote('Test note').signWith(signer);
      final eventMap = note.toMap();

      // Corrupt the signature (change last character)
      final sig = eventMap['sig'] as String;
      eventMap['sig'] = sig.substring(0, sig.length - 1) +
          (sig[sig.length - 1] == '0' ? '1' : '0');

      // Save - should not throw but should not save the event
      final savedIds = saveToDb({eventMap});
      expect(savedIds, isEmpty, reason: 'Corrupted signature event should be rejected');

      // Query should return empty
      final results = queryFromDb(
        'SELECT * FROM events WHERE id = :id',
        {':id': note.id},
      );
      expect(results, isEmpty, reason: 'Event should not be in database');
    });

    test('should reject event with mismatched pubkey', () async {
      // Create an event and then modify pubkey after signing
      final note = await PartialNote('Test note').signWith(signer);
      final eventMap = note.toMap();

      // Change pubkey to a different one (signature won't match)
      eventMap['pubkey'] = Utils.generateRandomHex64();

      final savedIds = saveToDb({eventMap});
      expect(savedIds, isEmpty, reason: 'Mismatched pubkey event should be rejected');
    });

    // NOTE: Tests for tampered content/kind/created_at are not included because
    // the current verifier only checks signature validity, not that the id
    // matches the hash of the event data. Tampering these fields while keeping
    // the same id would pass verification.

    test('should reject event with invalid id (not matching hash)', () async {
      final note = await PartialNote('Test note').signWith(signer);
      final eventMap = note.toMap();
      final originalId = note.id;

      // Change ID to something else (doesn't match event hash)
      eventMap['id'] = Utils.generateRandomHex64();

      final savedIds = saveToDb({eventMap});
      // Even if it tries to save, verification should fail
      expect(savedIds, isEmpty, reason: 'Non-matching ID event should be rejected');

      // Original ID should also not be in database
      final results = queryFromDb(
        'SELECT * FROM events WHERE id = :id',
        {':id': originalId},
      );
      expect(results, isEmpty);
    });

    test('should save multiple events and only keep valid ones', () async {
      // Create valid event
      final validNote = await PartialNote('Valid event').signWith(signer);
      final validMap = validNote.toMap();

      // Create invalid event (corrupted signature)
      final invalidNote = await PartialNote('Another event').signWith(signer);
      final invalidMap = invalidNote.toMap();
      // 128 char invalid signature
      invalidMap['sig'] = Utils.generateRandomHex64() + Utils.generateRandomHex64();

      // Save both
      final savedIds = saveToDb({validMap, invalidMap});

      // Only valid event should be saved
      expect(savedIds, hasLength(1), reason: 'Only valid event should be saved');
      expect(savedIds, contains(validNote.id));
      expect(savedIds, isNot(contains(invalidNote.id)));
    });

    test('verification enabled config should reject bad events', () async {
      // Verify our config has verification enabled
      expect(config.skipVerification, isFalse);

      final note = await PartialNote('Test').signWith(signer);
      final eventMap = note.toMap();
      // Use valid hex but completely wrong 128-char signature
      eventMap['sig'] = '00' * 64;

      final savedIds = saveToDb({eventMap});
      expect(savedIds, isEmpty, reason: 'Bad signature should be rejected');
    });

    test('skipVerification true config should accept any event', () async {
      // Create config with verification disabled
      final noVerifyConfig = StorageConfiguration(
        skipVerification: true,
      defaultRelays: {'test': {'wss://test.com'}},
      );

      final note = await PartialNote('Test').signWith(signer);
      final eventMap = note.toMap();
      eventMap['sig'] = 'invalid_signature';

      // Save with skipVerification=true should succeed
      final savedIds = db.save({eventMap}, {}, noVerifyConfig, verifier);
      expect(savedIds, isNotEmpty, reason: 'With skipVerification=true, any event should be accepted');
    });
  });
}

