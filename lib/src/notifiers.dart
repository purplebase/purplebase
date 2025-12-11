import 'package:purplebase/src/pool/state.dart';
import 'package:riverpod/riverpod.dart';

/// StateNotifier that manages pool state from the background isolate.
///
/// The PoolState contains:
/// - All subscriptions and their per-relay states
/// - Log entries (max 200) for debugging
///
/// State is updated when:
/// - Relay phase changes (connecting, loading, streaming, etc)
/// - Exceptions are caught
/// - Subscriptions are created or removed
class PoolStateNotifier extends StateNotifier<PoolState?> {
  PoolStateNotifier() : super(null);

  /// Called by the storage system to emit pool state updates
  void emit(PoolState poolState) {
    state = poolState;
  }

  /// Clear the current state
  void clear() {
    state = null;
  }
}

/// Provider for the pool state notifier
final poolStateProvider = StateNotifierProvider<PoolStateNotifier, PoolState?>(
  (ref) => PoolStateNotifier(),
);
