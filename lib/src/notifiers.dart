import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/pool/state/pool_state.dart';
import 'package:riverpod/riverpod.dart';

/// StateNotifier that manages messages from the background isolate
class InfoNotifier extends StateNotifier<InfoMessage?> {
  InfoNotifier() : super(null);

  /// Called by the storage system to emit a new message
  void emit(InfoMessage message) {
    state = message;
  }

  /// Clear the current message
  void clear() {
    state = null;
  }
}

/// Provider for the info notifier
final infoNotifierProvider = StateNotifierProvider<InfoNotifier, InfoMessage?>(
  (ref) => InfoNotifier(),
);

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
