import 'dart:async';

import 'package:models/models.dart';
import 'package:purplebase/src/pool/state/pool_state.dart';
import 'package:purplebase/src/pool/state/subscription_phase.dart';

/// Wraps a single active subscription
/// Tracks per-relay status and buffering
class ActiveSubscription {
  final Request request;
  final Set<String> targetRelays; // Normalized relay URLs
  final bool isStreaming;

  // Subscription phase
  SubscriptionPhase phase;
  DateTime startedAt;

  // Per-relay tracking
  final Map<String, RelaySubscriptionStatus> relayStatus;

  // Event buffering
  final Set<Map<String, dynamic>> bufferedEvents;
  final Map<String, Set<String>> relaysForEventId;
  int totalEventsReceived;

  // Timers
  Timer? eoseTimer;
  Timer? streamingFlushTimer;

  // For query() calls
  Completer<List<Map<String, dynamic>>>? queryCompleter;

  ActiveSubscription({
    required this.request,
    required this.targetRelays,
    this.isStreaming = false,
  }) : phase = SubscriptionPhase.eose,
       startedAt = DateTime.now(),
       relayStatus = {},
       bufferedEvents = {},
       relaysForEventId = {},
       totalEventsReceived = 0;

  /// Update relay status
  void setRelayPhase(String relayUrl, RelaySubscriptionPhase phase) {
    final current = relayStatus[relayUrl];
    relayStatus[relayUrl] = RelaySubscriptionStatus(
      phase: phase,
      eoseReceivedAt: current?.eoseReceivedAt,
      reconnectionAttempts: current?.reconnectionAttempts ?? 0,
      lastReconnectAt: current?.lastReconnectAt,
    );
  }

  /// Mark EOSE received from relay
  void markEoseReceived(String relayUrl) {
    final current = relayStatus[relayUrl];
    relayStatus[relayUrl] = RelaySubscriptionStatus(
      phase: const SubscriptionActive(),
      eoseReceivedAt: DateTime.now(),
      reconnectionAttempts: current?.reconnectionAttempts ?? 0,
      lastReconnectAt: current?.lastReconnectAt,
    );
  }

  /// Mark relay as reconnecting
  void markReconnection(String relayUrl) {
    final current = relayStatus[relayUrl];
    relayStatus[relayUrl] = RelaySubscriptionStatus(
      phase: const SubscriptionResyncing(),
      eoseReceivedAt: null, // Will receive new EOSE
      reconnectionAttempts: (current?.reconnectionAttempts ?? 0) + 1,
      lastReconnectAt: DateTime.now(),
    );
  }

  /// Check if all target relays have sent EOSE
  bool get allEoseReceived {
    return targetRelays.every((url) {
      final status = relayStatus[url];
      return status?.eoseReceivedAt != null;
    });
  }

  /// Add event to buffer (with deduplication)
  bool addEvent(String relayUrl, Map<String, dynamic> event) {
    final eventId = event['id'] as String?;
    if (eventId == null) return false;

    // Check if already buffered
    if (bufferedEvents.any((e) => e['id'] == eventId)) {
      // Just track which relay sent it
      relaysForEventId.putIfAbsent(eventId, () => {}).add(relayUrl);
      return false;
    }

    // Add to buffer
    bufferedEvents.add(event);
    relaysForEventId.putIfAbsent(eventId, () => {}).add(relayUrl);
    totalEventsReceived++;

    return true;
  }

  /// Clear event buffer
  void clearBuffer() {
    bufferedEvents.clear();
    relaysForEventId.clear();
  }

  /// Clean up all resources
  void dispose() {
    eoseTimer?.cancel();
    streamingFlushTimer?.cancel();
    if (queryCompleter != null && !queryCompleter!.isCompleted) {
      queryCompleter!.complete([]);
    }
  }
}
