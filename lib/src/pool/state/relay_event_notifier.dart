import 'package:models/models.dart';
import 'package:riverpod/riverpod.dart';

/// Base class for relay events (data channel)
sealed class RelayEvent {}

/// Events received from subscriptions
final class EventsReceived extends RelayEvent {
  final Request req;
  final Set<Map<String, dynamic>> events;
  final Map<String, Set<String>> relaysForIds;

  EventsReceived({
    required this.req,
    required this.events,
    required this.relaysForIds,
  });
}

/// Notice received from relay
final class NoticeReceived extends RelayEvent {
  final String message;
  final String relayUrl;

  NoticeReceived({required this.message, required this.relayUrl});
}

/// StateNotifier for relay events (data channel)
/// Emits events and notices as they arrive from relays
class RelayEventNotifier extends StateNotifier<RelayEvent?> {
  RelayEventNotifier() : super(null);

  void emitEvents({
    required Request req,
    required Set<Map<String, dynamic>> events,
    required Map<String, Set<String>> relaysForIds,
  }) {
    state = EventsReceived(
      req: req,
      events: events,
      relaysForIds: relaysForIds,
    );
  }

  void emitNotice({required String message, required String relayUrl}) {
    state = NoticeReceived(message: message, relayUrl: relayUrl);
  }
}





