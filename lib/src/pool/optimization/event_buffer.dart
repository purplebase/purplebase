import 'dart:async';

/// Event buffering and batching utility
/// Batches events together with a configurable window for efficient emission
class EventBuffer {
  final Duration batchWindow;
  final void Function(
    Set<Map<String, dynamic>> events,
    Map<String, Set<String>> relaysForIds,
  )
  onFlush;

  Timer? _flushTimer;
  final Set<Map<String, dynamic>> _buffer = {};
  final Map<String, Set<String>> _relaysForId = {};

  EventBuffer({required this.batchWindow, required this.onFlush});

  /// Add event to buffer (with automatic deduplication)
  /// Returns true if event was new, false if duplicate
  bool addEvent(String relayUrl, Map<String, dynamic> event) {
    final eventId = event['id'] as String?;
    if (eventId == null) return false;

    // Check if already buffered
    final isDuplicate = _buffer.any((e) => e['id'] == eventId);

    if (isDuplicate) {
      // Just track which relay sent it
      _relaysForId.putIfAbsent(eventId, () => {}).add(relayUrl);
      return false;
    }

    // Add to buffer
    _buffer.add(event);
    _relaysForId.putIfAbsent(eventId, () => {}).add(relayUrl);

    _scheduleBatch();
    return true;
  }

  /// Schedule batch flush
  void _scheduleBatch() {
    // Cancel existing timer if any
    _flushTimer?.cancel();

    // Schedule new flush
    _flushTimer = Timer(batchWindow, _flush);
  }

  /// Flush buffer immediately
  void _flush() {
    if (_buffer.isEmpty) return;

    // Create copies to avoid clearing while callback is using them
    final eventsCopy = Set<Map<String, dynamic>>.from(_buffer);
    final relaysCopy = Map<String, Set<String>>.from(_relaysForId);

    // Clear buffer
    _buffer.clear();
    _relaysForId.clear();

    // Invoke callback
    onFlush(eventsCopy, relaysCopy);
  }

  /// Flush immediately (for testing or forced flush)
  void flushNow() {
    _flushTimer?.cancel();
    _flush();
  }

  /// Get current buffer size
  int get bufferSize => _buffer.length;

  /// Dispose and cancel timers
  void dispose() {
    _flushTimer?.cancel();
    _buffer.clear();
    _relaysForId.clear();
  }
}


