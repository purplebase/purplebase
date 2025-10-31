import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:models/models.dart';

/// Request optimization with LRU timestamp cache
/// Adds 'since' filters to avoid re-fetching old events
class RequestOptimizer {
  final int maxEntries;

  // LRU cache: hash -> timestamp
  final Map<String, DateTime> _cache = {};
  final List<String> _lruKeys = []; // For LRU ordering

  RequestOptimizer({this.maxEntries = 1000});

  /// Optimize request for a specific relay based on stored timestamps
  /// Returns original request if:
  /// - isStreaming is true (never optimize streaming subscriptions)
  /// - No stored timestamp found for this relay-request pair
  Request optimize(
    String relayUrl,
    Request original, {
    required bool isStreaming,
  }) {
    if (isStreaming) {
      // NEVER optimize streaming subscriptions - they must receive ALL events
      return original;
    }

    final timestamp = _getTimestamp(relayUrl, original);
    if (timestamp == null) {
      // No stored timestamp, return original request
      return original;
    }

    // Create optimized filters with since timestamp
    final optimizedFilters = original.filters.map((filter) {
      // If filter has a newer since value, keep it; otherwise use stored timestamp
      if (filter.since != null && filter.since!.isAfter(timestamp)) {
        return filter;
      }
      return filter.copyWith(since: timestamp);
    }).toList();

    // Extract subscription prefix
    final prefix = _extractSubscriptionPrefix(original.subscriptionId);
    return Request(optimizedFilters, subscriptionPrefix: prefix);
  }

  /// Record event timestamp for future optimization
  void recordEvent(String relayUrl, Request req, DateTime eventTime) {
    final hash = _hashRelayRequestPair(relayUrl, req);

    // Remove from LRU list if it exists
    _lruKeys.remove(hash);

    // Add to front of LRU list
    _lruKeys.insert(0, hash);

    // Store the timestamp
    _cache[hash] = eventTime;

    // Evict oldest if we exceed max entries
    if (_lruKeys.length > maxEntries) {
      final oldestKey = _lruKeys.removeLast();
      _cache.remove(oldestKey);
    }
  }

  /// Get stored timestamp for relay-request pair
  DateTime? _getTimestamp(String relayUrl, Request req) {
    final hash = _hashRelayRequestPair(relayUrl, req);
    return _cache[hash];
  }

  /// Hash a relay-request pair for cache key
  String _hashRelayRequestPair(String relayUrl, Request req) {
    // Use canonical request (without since) for consistent hashing
    final canonicalReq = _canonicalRequest(req);
    final data = utf8.encode(relayUrl + canonicalReq.toString());
    final digest = sha256.convert(data);
    return digest.toString();
  }

  /// Create a canonical version of the request for hashing (without since/until)
  Request _canonicalRequest(Request req) {
    final canonicalFilters = req.filters.map((filter) {
      // Only remove since for optimization, keep until as it's a query constraint
      return filter.copyWith(since: DateTime.fromMillisecondsSinceEpoch(0));
    }).toList();
    final prefix = _extractSubscriptionPrefix(req.subscriptionId);
    return Request(canonicalFilters, subscriptionPrefix: prefix);
  }

  /// Extract the subscription prefix from a subscriptionId (format: "prefix-randomNumber")
  String _extractSubscriptionPrefix(String subscriptionId) {
    final lastDashIndex = subscriptionId.lastIndexOf('-');
    if (lastDashIndex == -1) return subscriptionId;
    return subscriptionId.substring(0, lastDashIndex);
  }

  /// Clear all cached timestamps
  void clear() {
    _cache.clear();
    _lruKeys.clear();
  }

  /// Get current cache size
  int get cacheSize => _cache.length;
}


