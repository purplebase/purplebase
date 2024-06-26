part of purplebase;

final relayMessageNotifierProvider =
    StateNotifierProvider<RelayMessageNotifier, RelayMessage>(
        (_) => RelayMessageNotifier());

class RelayMessageNotifier extends StateNotifier<RelayMessage> {
  RelayMessageNotifier() : super(NothingRelayMessage());
  late final WebSocketPool pool;
  StreamSubscription? _sub;
  StreamSubscription? _streamSub;
  final closeFns = <String, void Function()>{};

  Future<List<Map<String, dynamic>>> query(RelayRequest req,
      {Iterable<String>? relayUrls}) async {
    final completer = Completer<List<Map<String, dynamic>>>();
    final events = <Map<String, dynamic>>[];
    final eoses = <String, bool>{
      for (final r in (relayUrls ?? pool.relayUrls)) r: false
    };

    pool.send(jsonEncode(["REQ", req.subscriptionId, req.toMap()]),
        relayUrls: relayUrls);

    closeFns[req.subscriptionId] = addListener((message) {
      if (req.subscriptionId != message.subscriptionId) {
        return;
      }
      if (message is EventRelayMessage) {
        // print('recv message frame for sub ${message.subscriptionId}');
        events.add(message.event);
      }
      if (message is EoseRelayMessage) {
        eoses[message.relayUrl!] = true;
        if (eoses.values.reduce((acc, e) => acc && e) &&
            !completer.isCompleted) {
          completer.complete(events);
          scheduleMicrotask(() {
            closeFns[req.subscriptionId]?.call();
          });
        }
      }
    }, fireImmediately: false);

    return completer.future;
  }

  Future<void> publish(BaseEvent event, {Iterable<String>? relayUrls}) async {
    pool.send(jsonEncode(["EVENT", event.toMap()]), relayUrls: relayUrls);
  }

  RelayMessage get relayMessage {
    return super.state;
  }

  void initialize(Iterable<String> relays) {
    pool = WebSocketPool(relays);

    _sub = pool.stream.listen((record) {
      final (relayUrl, data) = record;
      final [type, subscriptionId, ...rest] = jsonDecode(data) as List;
      try {
        switch (type) {
          case 'EVENT':
            final map = rest.first;
            // TODO check if already in database with some callback
            // to skip double verification
            if (bip340.verify(map['pubkey'], map['id'], map['sig'])) {
              final event = rest.first as Map<String, dynamic>;
              state = EventRelayMessage(
                relayUrl: relayUrl,
                event: event,
                subscriptionId: subscriptionId,
              );
            }
            break;
          case 'NOTICE':
            state = NoticeRelayMessage(
                relayUrl: relayUrl,
                subscriptionId: subscriptionId,
                message: rest.toString());
          case 'EOSE':
            state = EoseRelayMessage(
              relayUrl: relayUrl,
              subscriptionId: subscriptionId,
            );
            break;
          default:
        }
      } catch (err) {
        state = ErrorRelayMessage(
            relayUrl: relayUrl,
            subscriptionId: subscriptionId,
            error: err.toString());
        _sub?.cancel();
        _streamSub?.cancel();
        closeFns[subscriptionId]?.call();
      }
    });
  }

  @override
  Future<void> dispose() async {
    for (final closeFn in closeFns.values) {
      closeFn.call();
    }
    await pool.close();
    _sub?.cancel();
    _streamSub?.cancel();
    if (mounted) {
      super.dispose();
    }
  }
}

final random = Random();

class RelayRequest {
  late final String subscriptionId;
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
      this.limit}) {
    subscriptionId = 'sub-${random.nextInt(999999)}';
  }

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
