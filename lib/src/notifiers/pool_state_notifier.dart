import 'package:riverpod/riverpod.dart';

import '../pool/pool_state.dart';

/// StateNotifier that manages pool state from the background isolate.
class PoolStateNotifier extends StateNotifier<PoolState?> {
  PoolStateNotifier() : super(null);

  void emit(PoolState poolState) {
    state = poolState;
  }

  void clear() {
    state = null;
  }
}

/// Provider for the pool state notifier.
final poolStateProvider = StateNotifierProvider<PoolStateNotifier, PoolState?>(
  (ref) => PoolStateNotifier(),
);
