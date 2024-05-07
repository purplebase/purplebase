part of purplebase;

final relayMessageNotifierProvider =
    StateNotifierProvider<RelayMessageNotifier, RelayMessage>(
        (_) => RelayMessageNotifier());

class RelayMessageNotifier extends StateNotifier<RelayMessage> {
  RelayMessageNotifier() : super(NothingRelayMessage());
  final random = Random();
  late final WebSocketPool pool;
  StreamSubscription? _sub;
  StreamSubscription? _streamSub;
  void Function()? close;

  Future<List<Map<String, dynamic>>> query(RelayRequest req,
      {Iterable<String>? relayUrls}) async {
    final completer = Completer<List<Map<String, dynamic>>>();
    final events = <Map<String, dynamic>>[];
    final eoses = <String, bool>{for (final r in pool.relayUrls) r: false};

    pool.send(jsonEncode(["REQ", 'sub-${random.nextInt(999999)}', req.toMap()]),
        relayUrls: relayUrls);

    close = addListener((message) {
      // print('recv frame $message');
      if (message is EventRelayMessage) {
        events.add(message.event);
      }
      if (message is EoseRelayMessage) {
        eoses[message.relayUrl!] = true;
        if (eoses.values.reduce((acc, e) => acc && e) &&
            !completer.isCompleted) {
          completer.complete(events);
          scheduleMicrotask(() => close?.call());
        }
      }
    }, fireImmediately: false);

    return completer.future;
  }

  Future<void> publish(BaseEvent event) async {
    pool.send(jsonEncode(["EVENT", event.toMap()]));
  }

  RelayMessage get relayMessage {
    return super.state;
  }

  void initialize(Iterable<String> relays) {
    try {
      pool = WebSocketPool(relays);

      _sub = pool.stream.listen((record) {
        final (relayUrl, data) = record;
        final [type, subscriptionId, ...rest] = jsonDecode(data) as List;
        switch (type) {
          case 'EVENT':
            final map = rest.first;
            if (bip340.verify(map['pubkey'], map['id'], map['sig'])) {
              final event = rest.first as Map<String, dynamic>;
              state = EventRelayMessage(
                  relayUrl: relayUrl,
                  event: event,
                  subscriptionId: subscriptionId);
            }
            break;
          case 'NOTICE':
            state =
                NoticeRelayMessage(relayUrl: relayUrl, message: subscriptionId);
          case 'EOSE':
            state = EoseRelayMessage(
                relayUrl: relayUrl, subscriptionId: subscriptionId);
            break;
          default:
        }
      });
    } catch (err) {
      state = ErrorRelayMessage(error: err.toString());
      _sub?.cancel();
      _streamSub?.cancel();
      close?.call();
    }
  }

  @override
  void dispose() async {
    await pool.close();
    _sub?.cancel();
    super.dispose();
  }
}

class RelayRequest {
  final Set<String> ids;
  final Set<int> kinds;
  final Set<String> authors;
  final Map<String, dynamic> tags;
  final String? search;
  final DateTime? since;
  final int? limit;

  RelayRequest(
      {this.ids = const {},
      this.kinds = const {},
      this.authors = const {},
      this.tags = const {},
      this.search,
      this.since,
      this.limit});

  Map<String, dynamic> toMap() {
    return {
      if (ids.isNotEmpty) 'ids': ids.toList(),
      if (kinds.isNotEmpty) 'kinds': kinds.toList(),
      if (authors.isNotEmpty) 'authors': authors.toList(),
      for (final e in tags.entries)
        e.key: e.value is Iterable ? e.value.toList() : e.value,
      if (since != null) 'since': since!.millisecondsSinceEpoch / 1000,
      if (limit != null) 'limit': limit,
      if (search != null) 'search': search,
    };
  }

  @override
  String toString() {
    return toMap().toString();
  }
}

sealed class RelayMessage {
  final String? relayUrl;
  final String? subscriptionId;
  RelayMessage({this.relayUrl, this.subscriptionId});

  @override
  String toString() {
    return '$runtimeType [$subscriptionId]';
  }
}

class NothingRelayMessage extends RelayMessage {
  NothingRelayMessage();
}

class EventRelayMessage extends RelayMessage {
  final Map<String, dynamic> event;

  EventRelayMessage({
    super.relayUrl,
    required this.event,
    required super.subscriptionId,
  });

  @override
  String toString() {
    return '${super.toString()}: $event';
  }
}

class NoticeRelayMessage extends RelayMessage {
  final String message;

  NoticeRelayMessage(
      {super.relayUrl, super.subscriptionId, required this.message});
}

class EoseRelayMessage extends RelayMessage {
  EoseRelayMessage({super.relayUrl, required super.subscriptionId});
}

class ErrorRelayMessage extends RelayMessage {
  final String error;
  ErrorRelayMessage(
      {super.relayUrl, super.subscriptionId, required this.error});
}
