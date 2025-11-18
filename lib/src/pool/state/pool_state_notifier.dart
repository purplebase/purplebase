import 'dart:async';

import 'package:purplebase/src/pool/state/pool_state.dart';
import 'package:riverpod/riverpod.dart';

/// StateNotifier for pool state with throttling support
class PoolStateNotifier extends StateNotifier<PoolState> {
  final Duration? _throttleDuration;
  DateTime? _lastUpdate;
  bool _updatePending = false;
  PoolState? _pendingState;

  PoolStateNotifier({Duration? throttleDuration})
    : _throttleDuration = throttleDuration,
      super(PoolState.initial());

  /// Get the current pool state
  PoolState get currentState => state;

  /// Update the entire state (throttled if configured)
  void update(PoolState newState) {
    if (_throttleDuration == null) {
      // No throttling
      state = newState;
      _lastUpdate = DateTime.now();
      return;
    }

    // Check if we should throttle
    final now = DateTime.now();
    if (_lastUpdate == null ||
        now.difference(_lastUpdate!) >= _throttleDuration) {
      // Emit immediately
      state = newState;
      _lastUpdate = now;
      _updatePending = false;
      _pendingState = null;
    } else {
      // Store pending update
      _pendingState = newState;
      if (!_updatePending) {
        _updatePending = true;
        // Schedule emission after throttle period
        final remaining =
            _throttleDuration.inMilliseconds -
            now.difference(_lastUpdate!).inMilliseconds;
        Future.delayed(Duration(milliseconds: remaining), () {
          if (_updatePending && _pendingState != null) {
            state = _pendingState!;
            _lastUpdate = DateTime.now();
            _updatePending = false;
            _pendingState = null;
          }
        });
      }
    }
  }
}





