import 'dart:async';

/// Helper for buffering, deduplicating, and batching events for a subscription
/// Tracks EOSE from multiple relays and handles flush timing
class SubscriptionBuffer {
  final String subscriptionId;
  final Set<String> targetRelays;
  final bool isStreaming;
  final Duration batchWindow;

  /// Request filters for this subscription (for UI/debugging)
  final List<Map<String, dynamic>> filters;

  // Event buffering and deduplication
  final Map<String, Map<String, dynamic>> _eventsById = {};
  final Map<String, Set<String>> _relaysForEventId = {};

  // EOSE tracking
  final Set<String> eoseReceived = {};
  final Map<String, DateTime> eoseReceivedAt =
      {}; // Track when each relay sent EOSE
  final Completer<void> _eoseCompleter = Completer<void>();

  // Batch timing
  Timer? _batchTimer;
  final void Function(
    List<Map<String, dynamic>> events,
    Map<String, Set<String>> relaysForIds,
  )
  onFlush;

  // For query() completers
  Completer<List<Map<String, dynamic>>>? queryCompleter;

  // Timers
  Timer? eoseFirstFlushTimer; // First flush after some EOSE received
  Timer? eoseFinalTimeoutTimer; // Final timeout to remove stuck relays

  // Callbacks for timeout handlers
  final void Function(String subscriptionId)? onFirstFlushTimeout;
  final void Function(String subscriptionId)? onFinalTimeout;

  // Metrics
  int totalEventsReceived = 0;
  final DateTime startedAt = DateTime.now();

  SubscriptionBuffer({
    required this.subscriptionId,
    required this.targetRelays,
    required this.isStreaming,
    required this.onFlush,
    this.onFirstFlushTimeout,
    this.onFinalTimeout,
    this.filters = const [],
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
      totalEventsReceived++;

      // Schedule batch flush if not already scheduled
      if (isStreaming) {
        _scheduleBatchFlush();
      }
    }
  }

  /// Mark EOSE received from a relay
  void markEose(String relayUrl) {
    final isFirstEose = eoseReceived.isEmpty;

    eoseReceived.add(relayUrl);
    eoseReceivedAt[relayUrl] = DateTime.now(); // Track when EOSE was received

    // Check if all target relays sent EOSE
    final allEose = eoseReceived.containsAll(targetRelays);

    // If all target relays sent EOSE, complete the completer
    if (allEose && !_eoseCompleter.isCompleted) {
      _eoseCompleter.complete();

      // Cancel first flush timer since we got all EOSEs
      eoseFirstFlushTimer?.cancel();
      eoseFirstFlushTimer = null;

      // For non-streaming subscriptions, flush immediately on EOSE
      if (!isStreaming) {
        flush();
      }
    } else if (isFirstEose && onFirstFlushTimeout != null) {
      // If this is the first EOSE but not all relays have EOSE'd, schedule first flush
      onFirstFlushTimeout!(subscriptionId);
    }
  }

  /// Check if all target relays have sent EOSE
  bool get allEoseReceived => eoseReceived.containsAll(targetRelays);

  /// Wait for all EOSE (for foreground queries)
  Future<void> waitForEose() => _eoseCompleter.future;

  /// Schedule a batch flush after the batch window
  void _scheduleBatchFlush() {
    if (_batchTimer?.isActive == true) return;

    _batchTimer = Timer(batchWindow, flush);
  }

  /// Flush buffered events
  void flush() {
    _batchTimer?.cancel();
    _batchTimer = null;

    // Create copies for callback
    final events = _eventsById.values.toList();
    final relaysForIds = Map<String, Set<String>>.from(_relaysForEventId);

    // Emit events (only if not empty)
    if (events.isNotEmpty) {
      onFlush(events, relaysForIds);
    }

    // Complete query completer if waiting (even if empty)
    if (queryCompleter != null && !queryCompleter!.isCompleted) {
      queryCompleter!.complete(List.from(events));
    }

    // For streaming subscriptions, clear buffer after flush
    // For non-streaming, keep events until subscription closes
    if (isStreaming) {
      _eventsById.clear();
      _relaysForEventId.clear();
    }
  }

  /// Get all buffered events (for non-streaming queries)
  List<Map<String, dynamic>> getAllEvents() => _eventsById.values.toList();

  /// Get relay information for buffered events
  Map<String, Set<String>> getRelaysForEvents() =>
      Map<String, Set<String>>.from(_relaysForEventId);

  /// Dispose buffer and clean up timers
  void dispose() {
    _batchTimer?.cancel();
    eoseFirstFlushTimer?.cancel();
    eoseFinalTimeoutTimer?.cancel();

    if (queryCompleter != null && !queryCompleter!.isCompleted) {
      queryCompleter!.complete([]);
    }
  }
}
