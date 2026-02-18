import 'dart:async';

/// Buffer for event deduplication and batching.
///
/// Collects events from multiple relays, deduplicates by event ID,
/// tracks relay sightings, and flushes on EOSE or batch timer.
class EventBuffer {
  final String subscriptionId;
  final Duration batchWindow;
  final int totalRelayCount;
  final void Function(
    List<Map<String, dynamic>> events,
    Map<String, Set<String>> relaysForIds,
  ) onFlush;

  /// Called on EOSE for each relay with (eventCount, relayUrl).
  final void Function(int eventCount, String relayUrl) onEose;

  Completer<List<Map<String, dynamic>>>? queryCompleter;
  Timer? eoseTimeoutTimer;

  final Map<String, Map<String, dynamic>> _eventsById = {};
  final Map<String, Set<String>> _relaysForEventId = {};
  final Set<String> _eoseReceived = {};
  Timer? _batchTimer;
  bool _flushedOnce = false;

  EventBuffer({
    required this.subscriptionId,
    required this.batchWindow,
    required this.totalRelayCount,
    required this.onFlush,
    required this.onEose,
    this.queryCompleter,
  });

  /// Whether this buffer has a blocking query waiting for results.
  bool get isBlocking => queryCompleter != null;

  /// Returns true if this was a new unique event (not a duplicate).
  bool addEvent(String relayUrl, Map<String, dynamic> event) {
    final eventId = event['id'] as String?;
    if (eventId == null) return false;

    _relaysForEventId.putIfAbsent(eventId, () => {}).add(relayUrl);

    if (!_eventsById.containsKey(eventId)) {
      _eventsById[eventId] = event;

      if (!isBlocking) {
        _scheduleBatchFlush();
      }
      return true;
    }
    return false;
  }

  /// Check if a specific event ID is in the buffer.
  bool hasEvent(String eventId) => _eventsById.containsKey(eventId);

  void markEose(String relayUrl) {
    final wasNewEose = _eoseReceived.add(relayUrl);
    if (!wasNewEose) return;

    final relayEventCount = _relaysForEventId.values
        .where((relays) => relays.contains(relayUrl))
        .length;
    onEose(relayEventCount, relayUrl);

    if (isBlocking) {
      if (_eoseReceived.length >= totalRelayCount) {
        flush();
      }
    } else {
      if (_eventsById.isNotEmpty) {
        flush();
      }
    }
  }

  /// Whether all relays have sent EOSE.
  bool get allEoseReceived => _eoseReceived.length >= totalRelayCount;

  /// Whether the buffer has been flushed at least once.
  bool get hasFlushed => _flushedOnce;

  void _scheduleBatchFlush() {
    if (_batchTimer?.isActive == true) return;
    _batchTimer = Timer(batchWindow, flush);
  }

  void flush() {
    _batchTimer?.cancel();
    _batchTimer = null;
    _flushedOnce = true;

    final events = _eventsById.values.toList();
    final relaysForIds = Map<String, Set<String>>.from(_relaysForEventId);

    if (events.isNotEmpty) {
      onFlush(events, relaysForIds);
    }

    if (queryCompleter != null && !queryCompleter!.isCompleted) {
      queryCompleter!.complete(List.from(events));
    }

    if (!isBlocking) {
      _eventsById.clear();
      _relaysForEventId.clear();
    }
  }

  void dispose() {
    _batchTimer?.cancel();
    eoseTimeoutTimer?.cancel();

    if (queryCompleter != null && !queryCompleter!.isCompleted) {
      queryCompleter!.complete([]);
    }
  }
}
