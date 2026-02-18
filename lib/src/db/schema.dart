/// DDL for the purplebase SQLite database.

/// Setup SQL: pragmas, tables, and indexes.
///
/// Includes the `deletions` table for NIP-09 tracking.
final setUpSql = '''
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
    is_relay  INTEGER NOT NULL
              CHECK (is_relay IN (0,1))
              DEFAULT 0,

    PRIMARY KEY (event_id, value),
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
  ) WITHOUT ROWID;

  CREATE INDEX IF NOT EXISTS value_idx ON event_tags(value);

  CREATE TABLE IF NOT EXISTS deletions (
    deleted_id TEXT NOT NULL PRIMARY KEY,
    deletion_event_id TEXT NOT NULL,
    deleted_at INTEGER NOT NULL
  ) WITHOUT ROWID;
''';

/// Teardown SQL: drop all tables.
final tearDownSql = '''
  DROP TABLE IF EXISTS deletions;
  DROP TABLE IF EXISTS event_tags;
  DROP TABLE IF EXISTS events;
''';
