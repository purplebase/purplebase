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
          result[entry.key] = statement
              .selectWith(StatementParameters.named(params))
              .decoded();
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
    Verifier verifier,
  ) {
    if (events.isEmpty) {
      return {};
    }

    // Event massaging
    final verifiedEvents = events
        // Filter events by verified
        .where((e) {
          return config.skipVerification ? true : verifier.verify(e);
        })
        .toSet();

    final (encodedEvents, tagsForId) = verifiedEvents.encoded(
      keepSignatures: config.keepSignatures,
    );

    // Get all IDs excluding replaceable events (which are inserted always)
    final incomingIds = verifiedEvents
        .where((e) => !Utils.isEventReplaceable(e['kind']))
        .map((p) => p['id'])
        .toList();

    final sql =
        '''
    SELECT id FROM events WHERE id IN (${incomingIds.map((_) => '?').join(', ')});
    INSERT INTO events (id, pubkey, kind, created_at, blob) 
    VALUES (:id, :pubkey, :kind, :created_at, :blob)
    ON CONFLICT(id) DO UPDATE SET
        pubkey = EXCLUDED.pubkey,
        kind = EXCLUDED.kind,
        created_at = EXCLUDED.created_at,
        blob = EXCLUDED.blob
    WHERE EXCLUDED.created_at > events.created_at;
    INSERT OR REPLACE INTO event_tags (event_id, value, is_relay) VALUES (:event_id, :value, :is_relay);
  ''';

    final [existingPs, eventPs, tagsPs] = prepareMultiple(sql);

    final ids = <String>{};
    try {
      final existingIds = existingPs
          .select(incomingIds)
          .map((e) => e['id'])
          .toSet();

      execute('BEGIN');
      for (final event in encodedEvents) {
        // Remember encoded events properties start with a colon
        // For replaceables, alreadySaved is always false
        final alreadySaved = existingIds.contains(event[':id']);
        final relayUrls = relaysForId[event[':id']] ?? {};

        // Normalize all relay URLs before storing
        final normalizedRelayUrls = relayUrls.map(normalizeRelayUrl).toSet();

        if (!alreadySaved) {
          eventPs.executeWith(StatementParameters.named(event));
          if (updatedRows > 0) {
            ids.add(event[':id']);
          }

          for (final List tag in tagsForId[event[':id']]!) {
            if (tag.length < 2 || tag[0].toString().length > 1) continue;
            tagsPs.executeWith(
              StatementParameters.named({
                ':event_id': event[':id'],
                ':value': '${tag[0]}:${tag[1]}',
                ':is_relay': false,
              }),
            );
          }

          for (final relayUrl in normalizedRelayUrls) {
            tagsPs.executeWith(
              StatementParameters.named({
                ':event_id': event[':id'],
                ':value': relayUrl,
                ':is_relay': true,
              }),
            );
          }
        } else {
          for (final relayUrl in normalizedRelayUrls) {
            tagsPs.executeWith(
              StatementParameters.named({
                ':event_id': event[':id'],
                ':value': relayUrl,
                ':is_relay': true,
              }),
            );
          }
          // Since we are updating relays only, do not add IDs to notify (for now)
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

  /// Delete events by IDs.
  /// Tags are automatically deleted via ON DELETE CASCADE.
  void delete(Set<String> ids) {
    if (ids.isEmpty) return;

    final sql =
        'DELETE FROM events WHERE id IN (${ids.map((_) => '?').join(', ')})';
    final statement = prepare(sql);

    try {
      execute('BEGIN');
      statement.execute(ids.toList());
      execute('COMMIT');
    } catch (e) {
      execute('ROLLBACK');
      rethrow;
    } finally {
      statement.dispose();
    }
  }
}

// 512 MB memory-mapped
final _setUpSql =
    '''
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA mmap_size = ${512 * 1024 * 1024};
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

  CREATE INDEX IF NOT EXISTS value_idx ON event_tags(value);
    ''';

final _tearDownSql = '''
  DROP TABLE IF EXISTS events;
  DROP TABLE IF EXISTS event_tags;
''';
