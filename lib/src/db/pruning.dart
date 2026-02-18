import 'package:sqlite3/sqlite3.dart';

/// Age-based pruning logic.
///
/// Removes old non-replaceable events from the database.
/// Replaceable events (kinds 0, 3, 10000-19999, 30000-39999) are never pruned.
extension PruningExt on Database {
  /// Prune events older than [olderThan].
  ///
  /// Returns the number of deleted events.
  int prune(Duration olderThan) {
    final cutoff =
        (DateTime.now().subtract(olderThan).millisecondsSinceEpoch ~/ 1000);

    execute('''
      DELETE FROM events
      WHERE created_at < ?
        AND kind NOT IN (0, 3)
        AND kind NOT BETWEEN 10000 AND 19999
        AND kind NOT BETWEEN 30000 AND 39999
    ''', [cutoff]);

    return updatedRows;
  }

  /// Checkpoint WAL to reclaim disk space after pruning.
  void walCheckpoint() {
    execute('PRAGMA wal_checkpoint(TRUNCATE);');
  }
}
