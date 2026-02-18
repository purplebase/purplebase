import 'package:models/models.dart';

/// Convert a [RequestFilter] to parameterized SQL.
///
/// Automatically adds: AND id NOT IN (SELECT deleted_id FROM deletions)
class QueryBuilder {
  static (String, Map<String, dynamic>) toSQL(RequestFilter filter,
      {Set<String>? seenOnRelays}) {
    final params = <String, dynamic>{};
    final whereClauses = <String>[];
    int paramIndex = 0;

    String nextParamName(String base) => ':${base}_${paramIndex++}';

    // IDs
    if (filter.ids.isNotEmpty) {
      final idParams = <String>[];
      for (final id in filter.ids) {
        final paramName = nextParamName('id');
        idParams.add(paramName);
        params[paramName] = id;
      }
      whereClauses.add('id IN (${idParams.join(', ')})');
    }

    // Kinds
    if (filter.kinds.isNotEmpty) {
      final kindParams = <String>[];
      for (final kind in filter.kinds) {
        final paramName = nextParamName('kind');
        kindParams.add(paramName);
        params[paramName] = kind;
      }
      whereClauses.add('kind IN (${kindParams.join(', ')})');
    }

    // Authors
    if (filter.authors.isNotEmpty) {
      final authorParams = <String>[];
      for (final author in filter.authors) {
        final paramName = nextParamName('author');
        authorParams.add(paramName);
        params[paramName] = author;
      }
      whereClauses.add('pubkey IN (${authorParams.join(', ')})');
    }

    // Tags — OR within same key, AND across different keys
    if (filter.tags.isNotEmpty) {
      for (final e in filter.tags.entries) {
        if (e.value.isEmpty) continue;

        final tagParams = <String>[];
        final tagKey = e.key.startsWith('#') ? e.key.substring(1) : e.key;

        for (final tagValue in e.value) {
          final paramName = nextParamName('tag');
          tagParams.add(paramName);
          params[paramName] = '$tagKey:$tagValue';
        }

        whereClauses.add(
          'id IN (SELECT event_id FROM event_tags WHERE value IN (${tagParams.join(', ')}))',
        );
      }
    }

    // Since
    if (filter.since != null) {
      final sinceParamName = nextParamName('since');
      whereClauses.add('created_at > $sinceParamName');
      params[sinceParamName] = filter.since!.millisecondsSinceEpoch ~/ 1000;
    }

    // Until
    if (filter.until != null) {
      final untilParamName = nextParamName('until');
      whereClauses.add('created_at < $untilParamName');
      params[untilParamName] = filter.until!.millisecondsSinceEpoch ~/ 1000;
    }

    // Exclude deleted events
    whereClauses.add('id NOT IN (SELECT deleted_id FROM deletions)');

    // SeenOnRelays — client-side filter applied at SQL level
    if (seenOnRelays != null && seenOnRelays.isNotEmpty) {
      final relayParams = <String>[];
      for (final relay in seenOnRelays) {
        final paramName = nextParamName('relay');
        relayParams.add(paramName);
        params[paramName] = relay;
      }
      whereClauses.add(
        'id IN (SELECT event_id FROM event_tags WHERE value IN (${relayParams.join(', ')}) AND is_relay = 1)',
      );
    }

    var sql = 'SELECT * FROM events';

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    sql += ' ORDER BY created_at DESC';

    // Limit
    if (filter.limit != null && filter.limit! > 0) {
      final limitParamName = nextParamName('limit');
      sql += ' LIMIT $limitParamName';
      params[limitParamName] = filter.limit!;
    }

    return (sql, params);
  }
}
