import 'package:bip340/bip340.dart' as bip340;
import 'package:models/models.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/utils.dart';
import 'package:sqlite3/sqlite3.dart';

extension DbExt on Database {
  Map<Request, List<Map<String, dynamic>>> find(
    Map<Request, LocalQueryArgs> args,
  ) {
    final result = <Request, List<Map<String, dynamic>>>{};
    List<PreparedStatement>? statements;

    try {
      for (final entry in args.entries) {
        statements = prepareMultiple(entry.value.queries.join(';\n'));
        for (final statement in statements) {
          final i = statements.indexOf(statement);
          final params = entry.value.params[i];
          result[entry.key] =
              statement.selectWith(StatementParameters.named(params)).decoded();
        }
      }
    } catch (e) {
      rethrow;
    } finally {
      if (statements != null) {
        for (final statement in statements) {
          statement.dispose();
        }
      }
    }
    return result;
  }

  Set<String> save(
    Set<Map<String, dynamic>> events,
    Map<String, Set<String>> relaysForId,
    StorageConfiguration config,
  ) {
    if (events.isEmpty) {
      return {};
    }

    // Event massaging
    final (encodedEvents, tagsForId) = events
        // Filter events by verified
        .where((e) {
          return config.skipVerification ? true : _verifyEvent(e);
        })
        .encoded(keepSignatures: config.keepSignatures);

    final incomingIds = events.map((p) => p['id']).toList();

    // TODO: If replacing event make sure date is latest!
    final sql = '''
    SELECT id FROM events WHERE id IN (${incomingIds.map((_) => '?').join(', ')});
    INSERT OR REPLACE INTO events (id, pubkey, kind, created_at, blob) VALUES (:id, :pubkey, :kind, :created_at, :blob);
    INSERT OR REPLACE INTO event_tags (event_id, value, is_relay) VALUES (:event_id, :value, :is_relay);
  ''';
    // TODO: And FTS?
    final [existingPs, eventPs, tagsPs] = prepareMultiple(sql);

    final ids = <String>{};
    try {
      final existingIds =
          existingPs.select(incomingIds).map((e) => e['id']).toSet();

      execute('BEGIN');
      for (final event in encodedEvents) {
        // Remember encoded events properties start with a colon
        // Also: :id can be a replaceable!
        final alreadySaved = existingIds.contains(event[':id']);
        final relayUrls = relaysForId[event[':id']] ?? {};

        if (!alreadySaved) {
          eventPs.executeWith(StatementParameters.named(event));
          if (updatedRows > 0) {
            ids.add(event[':id']);
          }

          for (final List tag in tagsForId[event[':id']]!) {
            // TODO: Allow specific tags to be indexed
            if (tag.length < 2 || tag[0].toString().length > 1) continue;
            tagsPs.executeWith(
              StatementParameters.named({
                ':event_id': event[':id'],
                ':value': '${tag[0]}:${tag[1]}',
                ':is_relay': false,
              }),
            );
          }

          for (final relayUrl in relayUrls) {
            tagsPs.executeWith(
              StatementParameters.named({
                ':event_id': event[':id'],
                ':value': relayUrl,
                ':is_relay': true,
              }),
            );
          }
        } else {
          print('just updating relay');
          for (final relayUrl in relayUrls) {
            tagsPs.executeWith(
              StatementParameters.named({
                ':event_id': event[':id'],
                ':value': relayUrl,
                ':is_relay': true,
              }),
            );
          }
          if (updatedRows > 0) {
            // If rows were updated then value changed, so notifier gets the ID
            // TODO: Won't trigger rebuild just for relay update, for now
            // ids.add(event[':id']);
          }
        }
      }
      execute('COMMIT');
    } catch (e) {
      execute('ROLLBACK');
      rethrow;
    } finally {
      existingPs.dispose();
      eventPs.dispose();
    }

    return ids;
  }

  void initialize({bool clear = false}) {
    // Drop all tables and set up again, deleting tables was problematic
    if (clear) {
      execute(_tearDownSql);
    }
    execute(_setUpSql);
  }

  // TODO: Faster validation via ffi?
  bool _verifyEvent(Map<String, dynamic> map) {
    bool verified = false;
    if (map['sig'] != null && map['sig'] != '') {
      verified = bip340.verify(map['pubkey'], map['id'], map['sig']);
      if (!verified) {
        print(
          '[purplebase] WARNING: Event ${map['id']} has an invalid signature',
        );
      }
    }
    return verified;
  }
}

// TODO: Fulltext search should be optional via config
final _setUpSql = '''
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA mmap_size = ${1 * 1024 * 1024 * 1024};
  PRAGMA page_size = 4096;
  PRAGMA cache_size = -20000;

  CREATE TABLE IF NOT EXISTS events(
    id TEXT NOT NULL PRIMARY KEY,
    pubkey TEXT NOT NULL,
    kind INTEGER NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    blob BLOB NOT NULL
  ) WITHOUT ROWID;

  CREATE INDEX IF NOT EXISTS pubkey_idx ON events(pubkey);
  CREATE INDEX IF NOT EXISTS kind_idx ON events(kind);
  CREATE INDEX IF NOT EXISTS created_at_idx ON events(created_at);

  CREATE TABLE IF NOT EXISTS event_tags (
    event_id  TEXT    NOT NULL,
    value     TEXT    NOT NULL,
    is_relay  INTEGER NOT NULL                -- 0 = no, 1 = yes
              CHECK (is_relay IN (0,1)) 
              DEFAULT 0,

    PRIMARY KEY (event_id, value),            -- composite PK
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
  ) WITHOUT ROWID;

  CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
    text,
    content='events',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 1',
    columnsize=0,
    detail=none
  );

  CREATE INDEX IF NOT EXISTS value_idx ON event_tags(value);
    ''';

// TODO: Add triggers, necessary for updates (replaceables) and deletions

final _tearDownSql = '''
  DROP TABLE IF EXISTS events;
  DROP TABLE IF EXISTS event_tags;
  DROP TABLE IF EXISTS events_fts;
''';
