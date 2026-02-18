import 'package:models/models.dart';

/// Author+kind query cache.
///
/// Tracks when (kind, author) pairs were last fetched from remote,
/// to support `cachedFor` on LocalAndRemoteSource queries.
class AuthorKindCache {
  final Map<String, DateTime> _timestamps = {};

  /// Check if all (kind, author) pairs in a filter are still fresh.
  bool isFresh(RequestFilter filter, Duration cachedFor) {
    if (!_isCacheableFilter(filter)) return false;

    final now = DateTime.now();
    return filter.authors.every((author) {
      return filter.kinds.every((kind) {
        final lastFetch = _timestamps['$kind:$author'];
        return lastFetch != null && now.difference(lastFetch) < cachedFor;
      });
    });
  }

  /// Return the set of stale authors for a filter.
  Set<String> staleAuthors(RequestFilter filter, Duration cachedFor) {
    if (!_isCacheableFilter(filter)) return filter.authors;

    final now = DateTime.now();
    return filter.authors.where((author) {
      return filter.kinds.any((kind) {
        final lastFetch = _timestamps['$kind:$author'];
        return lastFetch == null || now.difference(lastFetch) >= cachedFor;
      });
    }).toSet();
  }

  /// Mark filters as freshly fetched.
  void markFetched(List<RequestFilter> filters, DateTime timestamp) {
    for (final filter in filters) {
      if (!_isCacheableFilter(filter)) continue;
      for (final author in filter.authors) {
        for (final kind in filter.kinds) {
          _timestamps['$kind:$author'] = timestamp;
        }
      }
    }
  }

  void clear() => _timestamps.clear();

  /// A filter is cacheable if it has authors + kinds (all replaceable),
  /// and no ids, tags, search, or until.
  bool _isCacheableFilter(RequestFilter filter) {
    if (filter.authors.isEmpty) return false;
    if (filter.kinds.isEmpty) return false;
    if (!filter.kinds.every(Utils.isEventReplaceable)) return false;
    if (filter.ids.isNotEmpty) return false;
    if (filter.tags.isNotEmpty) return false;
    if (filter.search != null) return false;
    if (filter.until != null) return false;
    return true;
  }
}
