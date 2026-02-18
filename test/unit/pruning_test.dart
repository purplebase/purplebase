import 'dart:typed_data';

import 'package:purplebase/src/db/pruning.dart';
import 'package:purplebase/src/db/schema.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('Pruning', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
      db.execute(setUpSql);
    });

    tearDown(() => db.dispose());

    test('deletes non-replaceable events older than threshold', () {
      final oldTimestamp =
          (DateTime.now().subtract(Duration(days: 60)).millisecondsSinceEpoch ~/
              1000);
      final recentTimestamp =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000);

      db.execute(
        'INSERT INTO events (id, pubkey, kind, created_at, blob) VALUES (?, ?, ?, ?, ?)',
        ['old_event', 'pub1', 1, oldTimestamp, Uint8List(0)],
      );
      db.execute(
        'INSERT INTO events (id, pubkey, kind, created_at, blob) VALUES (?, ?, ?, ?, ?)',
        ['recent_event', 'pub1', 1, recentTimestamp, Uint8List(0)],
      );

      final deleted = db.prune(Duration(days: 30));
      expect(deleted, 1);

      final remaining = db.select('SELECT id FROM events');
      expect(remaining.length, 1);
      expect(remaining.first['id'], 'recent_event');
    });

    test('does not delete replaceable events', () {
      final oldTimestamp =
          (DateTime.now().subtract(Duration(days: 60)).millisecondsSinceEpoch ~/
              1000);

      db.execute(
        'INSERT INTO events (id, pubkey, kind, created_at, blob) VALUES (?, ?, ?, ?, ?)',
        ['0:pub1:', 'pub1', 0, oldTimestamp, Uint8List(0)],
      );
      db.execute(
        'INSERT INTO events (id, pubkey, kind, created_at, blob) VALUES (?, ?, ?, ?, ?)',
        ['10002:pub1:', 'pub1', 10002, oldTimestamp, Uint8List(0)],
      );
      db.execute(
        'INSERT INTO events (id, pubkey, kind, created_at, blob) VALUES (?, ?, ?, ?, ?)',
        ['30000:pub1:app', 'pub1', 30000, oldTimestamp, Uint8List(0)],
      );

      final deleted = db.prune(Duration(days: 30));
      expect(deleted, 0);

      final remaining = db.select('SELECT id FROM events');
      expect(remaining.length, 3);
    });

    test('returns zero when nothing to prune', () {
      final deleted = db.prune(Duration(days: 30));
      expect(deleted, 0);
    });

    test('walCheckpoint does not throw', () {
      expect(() => db.walCheckpoint(), returnsNormally);
    });
  });
}
