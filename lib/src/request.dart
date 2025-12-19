import 'dart:math';

import 'package:models/models.dart';

extension RequestFilterExt on RequestFilter {
  (String, Map<String, dynamic>) toSQL({Set<String>? relayUrls}) {
    final params = <String, dynamic>{};
    final whereClauses = <String>[];
    int paramIndex = 0; // Counter for unique parameter names

    // Helper function to generate unique parameter names
    String nextParamName(String base) => ':${base}_${paramIndex++}';

    // Handle IDs
    if (ids.isNotEmpty) {
      final idParams = <String>[];
      for (final id in ids) {
        final paramName = nextParamName('id');
        idParams.add(paramName);
        // Add to params with the leading ':'
        params[paramName] = id;
      }
      whereClauses.add('id IN (${idParams.join(', ')})');
    }

    // Handle Kinds
    if (kinds.isNotEmpty) {
      final kindParams = <String>[];
      for (final kind in kinds) {
        final paramName = nextParamName('kind');
        kindParams.add(paramName);
        params[paramName] = kind;
      }
      whereClauses.add('kind IN (${kindParams.join(', ')})');
    }

    // Handle Authors (pubkeys)
    if (authors.isNotEmpty) {
      final authorParams = <String>[];
      for (final author in authors) {
        final paramName = nextParamName('author');
        authorParams.add(paramName);
        params[paramName] = author;
      }
      whereClauses.add('pubkey IN (${authorParams.join(', ')})');
    }

    // Handle Tags
    if (tags.isNotEmpty) {
      // Tags semantics must be:
      // - OR within the same tag key (e.g. #t: {a,b})
      // - AND across different tag keys (e.g. #d AND #f)
      //
      // The previous implementation collapsed all tag pairs into a single
      // IN (...) clause, which incorrectly turned multi-tag filters into OR.
      for (final e in tags.entries) {
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

    // Handle Since (created_at > since)
    if (since != null) {
      final sinceParamName = nextParamName('since');
      whereClauses.add('created_at > $sinceParamName');
      // Convert DateTime to Unix timestamp (seconds)
      params[sinceParamName] = since!.millisecondsSinceEpoch ~/ 1000;
    }

    // Handle Until (created_at < until)
    if (until != null) {
      final untilParamName = nextParamName('until');
      whereClauses.add('created_at < $untilParamName');
      // Convert DateTime to Unix timestamp (seconds)
      params[untilParamName] = until!.millisecondsSinceEpoch ~/ 1000;
    }

    var sql = 'SELECT * FROM events';

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    // Add ordering (descending by creation time is standard for Nostr)
    sql += ' ORDER BY created_at DESC';

    // Handle Limit
    if (limit != null && limit! > 0) {
      final limitParamName = nextParamName('limit');
      sql += ' LIMIT $limitParamName';
      params[limitParamName] = limit!;
    }

    return (sql, params);
  }
}
