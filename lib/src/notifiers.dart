import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/pool/state.dart';
import 'package:riverpod/riverpod.dart';

/// StateNotifier that manages debug messages from the background isolate.
///
/// This notifier emits single debug messages (not accumulated) that clients can
/// listen to for logging, debugging, or monitoring purposes. Each message includes
/// a timestamp and component tag ([pool], [coordinator], etc.).
///
/// Messages are emitted by the WebSocketPool and ConnectionCoordinator during
/// various lifecycle events like connections, reconnections, subscriptions, etc.
///
/// Clients should accumulate these messages if they need historical logs.
class DebugNotifier extends StateNotifier<DebugMessage?> {
  DebugNotifier() : super(null);

  /// Called by the storage system to emit a new debug message
  void emit(DebugMessage message) {
    state = message;
  }

  /// Clear the current message
  void clear() {
    state = null;
  }
}

/// Provider for the debug notifier
final debugNotifierProvider =
    StateNotifierProvider<DebugNotifier, DebugMessage?>(
      (ref) => DebugNotifier(),
    );

/// Notifier for informational messages (user-visible notices/logs)
class InfoNotifier extends StateNotifier<InfoMessage?> {
  InfoNotifier() : super(null);

  void emit(InfoMessage message) {
    state = message;
  }

  void clear() {
    state = null;
  }
}

/// StateNotifier that manages pool state from the background isolate
class PoolStateNotifierProvider extends StateNotifier<PoolState?> {
  PoolStateNotifierProvider() : super(null);

  /// Called by the storage system to emit pool state updates
  void emit(PoolState poolState) {
    state = poolState;
  }

  /// Clear the current status
  void clear() {
    state = null;
  }
}

/// Provider for the pool state notifier
final poolStateProvider =
    StateNotifierProvider<PoolStateNotifierProvider, PoolState?>(
      (ref) => PoolStateNotifierProvider(),
    );

/// Legacy alias for backward compatibility
final relayStatusProvider = poolStateProvider;
