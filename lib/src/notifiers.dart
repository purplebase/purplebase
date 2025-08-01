import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/relay_status_types.dart';
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

/// StateNotifier that manages relay status from the background isolate
class RelayStatusNotifier extends StateNotifier<RelayStatusData?> {
  RelayStatusNotifier() : super(null);

  /// Called by the storage system to emit relay status updates
  void emit(RelayStatusData statusData) {
    state = statusData;
  }

  /// Clear the current status
  void clear() {
    state = null;
  }
}

/// Provider for the relay status notifier
final relayStatusProvider =
    StateNotifierProvider<RelayStatusNotifier, RelayStatusData?>(
      (ref) => RelayStatusNotifier(),
    );
