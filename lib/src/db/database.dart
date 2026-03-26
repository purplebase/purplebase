import 'package:models/models.dart';
import 'package:sqlite3/sqlite3.dart';

import '../isolate/messages.dart';
import 'codec.dart';
import 'schema.dart';

/// SQLite database operations for event storage.
extension DbExt on Database {
  /// Query the database for events matching the given request/args pairs.
  Map<Request, List<Map<String, dynamic>>> find(
    Map<Request, LocalQueryArgs> args,
  ) {
    final result = <Request, List<Map<String, dynamic>>>{};

    for (final entry in args.entries) {
      final statements = prepareMultiple(entry.value.queries.join(';\n'));
      try {
        final allEvents = <Map<String, dynamic>>[];
        for (var i = 0; i < statements.length; i++) {
          final params = entry.value.params[i];
          allEvents.addAll(EventCodec.decode(
            statements[i].selectWith(StatementParameters.named(params)),
          ));
        }
        result[entry.key] = allEvents;
      } finally {
        for (final statement in statements) {
          statement.dispose();
        }
      }
    }
    return result;
  }

  /// Save events to the database.
  ///
  /// Returns the set of storage IDs that were actually written (new or updated).
  /// If any events are kind 5, NIP-09 deletion logic is applied.
  Set<String> save(
    Set<Map<String, dynamic>> events,
    Map<String, Set<String>> relaysForId,
    StorageConfiguration config,
    Verifier verifier,
  ) {
    if (events.isEmpty) return {};

    final verifiedEvents = events
        .where((e) => config.skipVerification ? true : verifier.verify(e))
        .toSet();

    final (encodedEvents, tagsForId) = EventCodec.encode(
      verifiedEvents,
      keepSignatures: config.keepSignatures,
    );

    final incomingIds = verifiedEvents
        .where((e) => !Utils.isEventReplaceable(e['kind']))
        .map((p) => p['id'])
        .toList();

    final sql = '''
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
      final existingIds =
          existingPs.select(incomingIds).map((e) => e['id']).toSet();

      execute('BEGIN');
      for (final event in encodedEvents) {
        final alreadySaved = existingIds.contains(event[':id']);
        final relayUrls = relaysForId[event[':id']] ?? {};

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
          for (final relayUrl in relayUrls) {
            tagsPs.executeWith(
              StatementParameters.named({
                ':event_id': event[':id'],
                ':value': relayUrl,
                ':is_relay': true,
              }),
            );
          }
        }
      }

      // NIP-09: process deletion events
      for (final event in verifiedEvents) {
        if (event['kind'] == 5) {
          _processDeletion(event);
        }
      }

      execute('COMMIT');
    } catch (e) {
      execute('ROLLBACK');
      rethrow;
    } finally {
      existingPs.dispose();
      eventPs.dispose();
      tagsPs.dispose();
    }

    return ids;
  }

  /// Initialize the database schema. If [clear] is true, drops all tables first.
  void initialize({bool clear = false}) {
    if (clear) {
      execute(tearDownSql);
    }
    execute(setUpSql);
  }

  /// Delete events by IDs. Tags are automatically deleted via ON DELETE CASCADE.
  void deleteEvents(Set<String> ids) {
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

  /// Query relay URLs where an event has been seen.
  Set<String> queryRelaysForEvent(String eventId) {
    final result = select(
      'SELECT value FROM event_tags WHERE event_id = ? AND is_relay = 1',
      [eventId],
    );
    return result.map((r) => r['value'] as String).toSet();
  }

  // NIP-09 deletion processing
  void _processDeletion(Map<String, dynamic> event) {
    final tags = event['tags'] as List;
    final deletionEventId = event['id'] as String;
    final deletionAuthor = event['pubkey'] as String;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Process 'e' tags — direct event IDs
    final eTags = tags.where((t) => t[0] == 'e').map((t) => t[1] as String);
    for (final eventId in eTags) {
      execute('''
        INSERT OR IGNORE INTO deletions (deleted_id, deletion_event_id, deleted_at)
        SELECT ?, ?, ? FROM events WHERE id = ? AND pubkey = ?
      ''', [eventId, deletionEventId, now, eventId, deletionAuthor]);
      execute(
          'DELETE FROM events WHERE id = ? AND pubkey = ?',
          [eventId, deletionAuthor]);
    }

    // Process 'a' tags — coordinates (kind:pubkey:d)
    final aTags = tags.where((t) => t[0] == 'a').map((t) => t[1] as String);
    for (final coord in aTags) {
      final parts = coord.split(':');
      if (parts.length < 2 || parts[1] != deletionAuthor) continue;

      execute('INSERT OR IGNORE INTO deletions VALUES (?, ?, ?)',
          [coord, deletionEventId, now]);
      execute('DELETE FROM events WHERE id = ?', [coord]);
    }
  }
}
