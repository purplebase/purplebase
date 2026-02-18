import 'package:models/models.dart';
import 'package:purplebase/src/db/query_builder.dart';
import 'package:test/test.dart';

const _hex64 =
    'a9434ee165ed01b286becfc2771ef1705d3537d051b387288898cc00d5c885be';
const _hex64b =
    '7fa56f5d6962ab1e3cd424e758c3002b8665f7b0d8dcee9fe9e288d7751ac194';

void main() {
  group('QueryBuilder', () {
    test('empty filter generates SELECT with deletion exclusion', () {
      final (sql, _) = QueryBuilder.toSQL(RequestFilter());
      expect(sql, contains('SELECT * FROM events'));
      expect(sql, contains('id NOT IN (SELECT deleted_id FROM deletions)'));
      expect(sql, contains('ORDER BY created_at DESC'));
    });

    test('filter by ids', () {
      final (sql, params) = QueryBuilder.toSQL(
        RequestFilter(ids: {_hex64, _hex64b}),
      );
      expect(sql, contains('id IN'));
      expect(params.values.toSet(), containsAll([_hex64, _hex64b]));
    });

    test('filter by kinds', () {
      final (sql, params) = QueryBuilder.toSQL(
        RequestFilter(kinds: {1, 4}),
      );
      expect(sql, contains('kind IN'));
      expect(params.values.toSet(), containsAll([1, 4]));
    });

    test('filter by authors', () {
      final (sql, params) = QueryBuilder.toSQL(
        RequestFilter(authors: {_hex64}),
      );
      expect(sql, contains('pubkey IN'));
      expect(params.values, contains(_hex64));
    });

    test('filter by tags', () {
      final (sql, params) = QueryBuilder.toSQL(
        RequestFilter(tags: {
          '#t': {'nostr', 'bitcoin'},
        }),
      );
      expect(sql, contains('event_tags'));
      expect(params.values.toSet(), containsAll(['t:nostr', 't:bitcoin']));
    });

    test('multiple tag keys are ANDed', () {
      final (sql, _) = QueryBuilder.toSQL(
        RequestFilter(tags: {
          '#t': {'nostr'},
          '#p': {_hex64},
        }),
      );
      expect('event_tags'.allMatches(sql).length, greaterThanOrEqualTo(2));
    });

    test('filter by since', () {
      final since = DateTime(2024, 1, 1);
      final (sql, params) = QueryBuilder.toSQL(
        RequestFilter(since: since),
      );
      expect(sql, contains('created_at >'));
      expect(params.values, contains(since.millisecondsSinceEpoch ~/ 1000));
    });

    test('filter by until', () {
      final until = DateTime(2024, 12, 31);
      final (sql, params) = QueryBuilder.toSQL(
        RequestFilter(until: until),
      );
      expect(sql, contains('created_at <'));
      expect(params.values, contains(until.millisecondsSinceEpoch ~/ 1000));
    });

    test('filter with limit', () {
      final (sql, params) = QueryBuilder.toSQL(
        RequestFilter(kinds: {1}, limit: 10),
      );
      expect(sql, contains('LIMIT'));
      expect(params.values, contains(10));
    });

    test('always excludes deleted events', () {
      final (sql, _) = QueryBuilder.toSQL(RequestFilter(kinds: {1}));
      expect(sql, contains('NOT IN (SELECT deleted_id FROM deletions)'));
    });

    test('seenOnRelays adds relay filter', () {
      final (sql, params) = QueryBuilder.toSQL(
        RequestFilter(kinds: {1}),
        seenOnRelays: {'wss://relay.example.com'},
      );
      expect(sql, contains('is_relay = 1'));
      expect(params.values, contains('wss://relay.example.com'));
    });

    test('complex filter combines all clauses with AND', () {
      final (sql, _) = QueryBuilder.toSQL(
        RequestFilter(
          kinds: {1},
          authors: {_hex64},
          tags: {
            '#t': {'nostr'}
          },
          since: DateTime(2024, 1, 1),
          limit: 5,
        ),
      );
      expect(sql, contains('kind IN'));
      expect(sql, contains('pubkey IN'));
      expect(sql, contains('event_tags'));
      expect(sql, contains('created_at >'));
      expect(sql, contains('LIMIT'));
      expect(' AND '.allMatches(sql).length, greaterThanOrEqualTo(4));
    });
  });
}
