import 'package:purplebase/src/isolate.dart';
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
