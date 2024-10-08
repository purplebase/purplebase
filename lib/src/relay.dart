part of purplebase;

const kNotInitialized = 'Relay notifier was not initialized';

final relayMessageNotifierProvider = StateNotifierProvider.family<
    RelayMessageNotifier, RelayMessage, List<String>>((_, relayUrls) {
  return RelayMessageNotifier(relayUrls);
});

class RelayMessageNotifier extends StateNotifier<RelayMessage> {
  RelayMessageNotifier(List<String> relayUrls)
      : pool = WebSocketPool(relayUrls),
        super(NothingRelayMessage());
  final WebSocketPool pool;
  StreamSubscription? _sub;
  StreamSubscription? _streamSub;
  final _closeFns = <String, void Function()>{};
  var isInitialized = false;

  final _r = RegExp('error', caseSensitive: false);

  Future<List<Map<String, dynamic>>> queryRaw(RelayRequest req,
      {Iterable<String>? relayUrls}) async {
    if (!isInitialized) throw kNotInitialized;
    final completer = Completer<List<Map<String, dynamic>>>();
    final events = <Map<String, dynamic>>[];
    final eoses = <String, bool>{
      for (final r in (relayUrls ?? pool.relayUrls)) r: false
    };

    _closeFns[req.subscriptionId] = addListener((message) {
      if (message.subscriptionId != null &&
          req.subscriptionId != message.subscriptionId) {
        return;
      }

      if (message is EventRelayMessage) {
        events.add(message.event);
      }
      if (message is NoticeRelayMessage) {
        completer.completeError(Exception(message.text));
      }
      if (message is ErrorRelayMessage) {
        completer.completeError(Exception(message.error));
      }
      if (message is EoseRelayMessage) {
        eoses[message.relayUrl!] = true;
        if (eoses.values.reduce((acc, e) => acc && e) &&
            !completer.isCompleted) {
          completer.complete(events);
          scheduleMicrotask(() {
            _closeFns[req.subscriptionId]?.call();
          });
        }
      }
    }, fireImmediately: false);

    pool.send(jsonEncode(["REQ", req.subscriptionId, req.toMap()]),
        relayUrls: relayUrls);

    return completer.future;
  }

  Future<List<T>> query<T extends BaseEvent<T>>(
      {Set<String>? ids,
      Set<String>? authors,
      Map<String, dynamic>? tags,
      String? search,
      DateTime? since,
      int? limit,
      Iterable<String>? relayUrls}) async {
    final req = RelayRequest(
        kinds: {_kindFor<T>()},
        ids: ids ?? {},
        authors: authors ?? {},
        tags: tags ?? {},
        search: search,
        since: since,
        limit: limit);

    final result = await queryRaw(req);
    return result
        .map((map) => BaseEvent.ctorForKind<T>(map['kind'].toString().toInt()!)!
            .call(map))
        .toList();
  }

  Future<void> publish(BaseEvent event, {Iterable<String>? relayUrls}) async {
    if (!isInitialized) throw kNotInitialized;
    final completer = Completer<void>();
    pool.send(jsonEncode(["EVENT", event.toMap()]), relayUrls: relayUrls);
    _closeFns[event.id.toString()] = addListener((message) {
      if (message.subscriptionId != null &&
          event.id.toString() != message.subscriptionId) {
        return;
      }

      if (message is PublishedEventRelayMessage) {
        if (message.accepted) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        } else {
          if (!completer.isCompleted) {
            final error = message.message ?? 'Not accepted';
            completer.completeError(Exception(error));
          }
        }
      }
    });
    return completer.future;
  }

  RelayMessage get relayMessage {
    return super.state;
  }

  Future<RelayMessageNotifier> initialize(
      {bool Function(String eventId)? isEventVerified}) async {
    await pool.initialize();
    _sub = pool.stream.listen((record) {
      final (relayUrl, data) = record;
      final [type, subscriptionId, ...rest] = jsonDecode(data) as List;
      try {
        switch (type) {
          case 'EVENT':
            final map = rest.first;
            final alreadyVerified = isEventVerified?.call(map['id']) ?? false;
            if (alreadyVerified ||
                bip340.verify(map['pubkey'], map['id'], map['sig'])) {
              final event = rest.first as Map<String, dynamic>;
              state = EventRelayMessage(
                relayUrl: relayUrl,
                event: event,
                subscriptionId: subscriptionId,
              );
            }
            break;
          case 'NOTICE':
            if (_r.hasMatch(subscriptionId)) {
              state = ErrorRelayMessage(
                  relayUrl: relayUrl,
                  subscriptionId: null,
                  error: subscriptionId);
            }
          case 'CLOSED':
            state = ErrorRelayMessage(
                relayUrl: relayUrl,
                subscriptionId: subscriptionId,
                error: rest.join(', '));
          case 'EOSE':
            state = EoseRelayMessage(
              relayUrl: relayUrl,
              subscriptionId: subscriptionId,
            );
            break;
          case 'OK':
            state = PublishedEventRelayMessage(
              relayUrl: relayUrl,
              subscriptionId: subscriptionId,
              accepted: rest.first as bool,
              message: rest.lastOrNull?.toString(),
            );
            break;
          default:
        }
      } catch (err) {
        state = ErrorRelayMessage(
            relayUrl: relayUrl, subscriptionId: null, error: err.toString());
        _sub?.cancel();
        _streamSub?.cancel();
        _closeFns[subscriptionId]?.call();
      }
    });
    isInitialized = true;
    return this;
  }

  @override
  Future<void> dispose() async {
    isInitialized = false;
    for (final closeFn in _closeFns.values) {
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
  final String text;

  NoticeRelayMessage(
      {super.relayUrl, super.subscriptionId, required this.text});
}

class EoseRelayMessage extends RelayMessage {
  EoseRelayMessage({super.relayUrl, required super.subscriptionId});
}

class ErrorRelayMessage extends RelayMessage {
  final String error;
  ErrorRelayMessage(
      {super.relayUrl, super.subscriptionId, required this.error});
}

class PublishedEventRelayMessage extends RelayMessage {
  final bool accepted;
  final String? message;
  PublishedEventRelayMessage(
      {super.relayUrl,
      required super.subscriptionId,
      required this.accepted,
      this.message});
}
