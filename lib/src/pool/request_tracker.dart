import 'package:models/models.dart';

/// Active request tracking + exact-match deduplication at the pool level.
///
/// Prevents sending duplicate REQs when the same filter set is already active.
class RequestTracker {
  /// Active subscription filters, keyed by subscription ID.
  final Map<String, List<RequestFilter>> _activeFilters = {};

  /// Register a new subscription's filters.
  void register(String subId, List<RequestFilter> filters) {
    _activeFilters[subId] = filters;
  }

  /// Unregister a subscription.
  void unregister(String subId) {
    _activeFilters.remove(subId);
  }

  /// Check if an identical request is already active.
  /// Returns the covering subscription ID, or null if not found.
  String? findExact(List<RequestFilter> filters) {
    for (final entry in _activeFilters.entries) {
      if (_filtersEqual(entry.value, filters)) {
        return entry.key;
      }
    }
    return null;
  }

  bool _filtersEqual(List<RequestFilter> a, List<RequestFilter> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Check if a new request is fully covered by an active subscription.
  ///
  /// Conservative: only checks exact match for now.
  /// Superset matching can be added later.
  String? findCovering(List<RequestFilter> filters) {
    return findExact(filters);
  }
}
