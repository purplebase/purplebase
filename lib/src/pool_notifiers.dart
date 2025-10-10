import 'package:purplebase/src/relay_status_types.dart';
import 'package:purplebase/src/websocket_pool.dart';
import 'package:riverpod/riverpod.dart';

/// Base class for relay events (data channel)
sealed class RelayEvent {}

/// Events received from subscriptions
final class EventsReceived extends RelayEvent {
  final EventRelayResponse response;
  EventsReceived(this.response);
}

/// Notice received from relay
final class NoticeReceived extends RelayEvent {
  final NoticeRelayResponse response;
  NoticeReceived(this.response);
}

/// Notifier for relay events (data channel)
/// Emits events and notices as they arrive from relays
class RelayEventNotifier extends StateNotifier<RelayEvent?> {
  RelayEventNotifier() : super(null);

  void emitEvents(EventRelayResponse response) {
    state = EventsReceived(response);
  }

  void emitNotice(NoticeRelayResponse response) {
    state = NoticeReceived(response);
  }
}

/// Notifier for pool status (meta channel)
/// Provides queryable status of pool operations
class PoolStatusNotifier extends StateNotifier<PoolStatus> {
  static const int maxErrors = 100;
  DateTime? _lastUpdate;
  final Duration? _throttleDuration;
  bool _updatePending = false;
  PoolStatus? _pendingStatus;

  PoolStatusNotifier({Duration? throttleDuration})
    : _throttleDuration = throttleDuration,
      super(
        PoolStatus(
          connections: {},
          subscriptions: {},
          publishes: {},
          recentErrors: [],
          lastUpdated: DateTime.now(),
        ),
      );

  /// Get the current pool status
  PoolStatus get currentState => state;

  /// Update the entire status (throttled)
  void update(PoolStatus newStatus) {
    if (_throttleDuration == null) {
      // No throttling
      state = newStatus;
      _lastUpdate = DateTime.now();
      return;
    }

    // Check if we should throttle
    final now = DateTime.now();
    if (_lastUpdate == null ||
        now.difference(_lastUpdate!) >= _throttleDuration) {
      // Emit immediately
      state = newStatus;
      _lastUpdate = now;
      _updatePending = false;
      _pendingStatus = null;
    } else {
      // Store pending update
      _pendingStatus = newStatus;
      if (!_updatePending) {
        _updatePending = true;
        // Schedule emission after throttle period
        final remaining =
            _throttleDuration.inMilliseconds -
            now.difference(_lastUpdate!).inMilliseconds;
        Future.delayed(Duration(milliseconds: remaining), () {
          if (_updatePending && _pendingStatus != null) {
            state = _pendingStatus!;
            _lastUpdate = DateTime.now();
            _updatePending = false;
            _pendingStatus = null;
          }
        });
      }
    }
  }

  /// Log an error (maintains circular buffer)
  void logError(
    String message, {
    String? relayUrl,
    String? subscriptionId,
    String? eventId,
  }) {
    final error = ErrorEntry(
      timestamp: DateTime.now(),
      message: message,
      relayUrl: relayUrl,
      subscriptionId: subscriptionId,
      eventId: eventId,
    );

    final errors = List<ErrorEntry>.from(state.recentErrors)..add(error);

    // Maintain circular buffer (keep last N entries)
    if (errors.length > maxErrors) {
      errors.removeRange(0, errors.length - maxErrors);
    }

    state = state.copyWith(recentErrors: errors, lastUpdated: DateTime.now());
  }
}
