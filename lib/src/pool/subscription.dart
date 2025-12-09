import 'dart:async';

/// Subscription buffer for event deduplication and batching
class Subscription {
  final String subscriptionId;
  final List<Map<String, dynamic>> filters;
  final Set<String> targetRelays;
  final bool isStreaming;
  final Duration batchWindow;
  final void Function(List<Map<String, dynamic>> events, Map<String, Set<String>> relaysForIds) onFlush;

  // Event buffering
  final Map<String, Map<String, dynamic>> _eventsById = {};
  final Map<String, Set<String>> _relaysForEventId = {};

  // EOSE tracking
  final Set<String> eoseReceived = {};
  final Completer<void> _eoseCompleter = Completer<void>();

  // Batch timing
  Timer? _batchTimer;

  // Query completer for non-streaming queries
  Completer<List<Map<String, dynamic>>>? queryCompleter;

  // Timeouts
  Timer? eoseTimeoutTimer;

  // Metrics
  int eventCount = 0;
  final DateTime startedAt = DateTime.now();

  Subscription({
    required this.subscriptionId,
    required this.filters,
    required this.targetRelays,
    required this.isStreaming,
    required this.onFlush,
    this.batchWindow = const Duration(milliseconds: 50),
  });

  /// Add event from a relay (with deduplication)
  void addEvent(String relayUrl, Map<String, dynamic> event) {
    final eventId = event['id'] as String?;
    if (eventId == null) return;

    // Track which relay sent this event
    _relaysForEventId.putIfAbsent(eventId, () => {}).add(relayUrl);

    // Add event if not already buffered
    if (!_eventsById.containsKey(eventId)) {
      _eventsById[eventId] = event;
      eventCount++;

      // Schedule batch flush for streaming subscriptions
      if (isStreaming) {
        _scheduleBatchFlush();
      }
    }
  }

  /// Mark EOSE received from a relay
  void markEose(String relayUrl) {
    eoseReceived.add(relayUrl);

    // Check if all target relays sent EOSE
    if (allEoseReceived && !_eoseCompleter.isCompleted) {
      _eoseCompleter.complete();
      eoseTimeoutTimer?.cancel();

      // Flush events and complete queryCompleter
      // For non-streaming: this is the final result
      // For streaming: this is the initial batch, subscription stays open
      flush();
    }
  }

  /// Whether all target relays have sent EOSE
  bool get allEoseReceived => eoseReceived.containsAll(targetRelays);

  /// Schedule a batch flush after the batch window
  void _scheduleBatchFlush() {
    if (_batchTimer?.isActive == true) return;
    _batchTimer = Timer(batchWindow, flush);
  }

  /// Flush buffered events
  void flush() {
    _batchTimer?.cancel();
    _batchTimer = null;

    final events = _eventsById.values.toList();
    final relaysForIds = Map<String, Set<String>>.from(_relaysForEventId);

    // Emit events if not empty
    if (events.isNotEmpty) {
      onFlush(events, relaysForIds);
    }

    // Complete query completer if waiting
    if (queryCompleter != null && !queryCompleter!.isCompleted) {
      queryCompleter!.complete(List.from(events));
    }

    // Clear buffer for streaming subscriptions
    if (isStreaming) {
      _eventsById.clear();
      _relaysForEventId.clear();
    }
  }

  /// Get all buffered events (for non-streaming queries)
  List<Map<String, dynamic>> getAllEvents() => _eventsById.values.toList();

  /// Dispose and clean up
  void dispose() {
    _batchTimer?.cancel();
    eoseTimeoutTimer?.cancel();

    if (queryCompleter != null && !queryCompleter!.isCompleted) {
      queryCompleter!.complete([]);
    }
  }
}

