part of purplebase;

final relayProviderFamily = StateNotifierProvider.family<RelayMessageNotifier,
    RelayMessage, Set<String>>((_, relayUrls) {
  return RelayMessageNotifier(relayUrls);
});

class RelayMessageNotifier extends StateNotifier<RelayMessage> {
  WebSocketPool? pool;
  StreamSubscription? _sub;
  StreamSubscription? _streamSub;
  bool Function(Map<String, dynamic> event)? _isEventVerified;
  Ndk? ndk;

  final _closeFns = <String, void Function()>{};
  final _errorRegex = RegExp('error', caseSensitive: false);
  final _requests = <RelayRequest>{};
  final _resultsOnEose = <(String, String), List<Map<String, dynamic>>>{};

  RelayMessageNotifier(Set<String> relayUrls) : super(NothingRelayMessage()) {
    // TODO: Temporary hack to enable NDK
    // Get a mutable set (_relayUrls) from the immutable relayUrls
    // ignore: no_leading_underscores_for_local_identifiers
    final _relayUrls = relayUrls.toSet();
    if (_relayUrls.remove('ndk')) {
      ndk = Ndk(
        NdkConfig(
            eventVerifier: Bip340EventVerifier(),
            cache: MemCacheManager(),
            bootstrapRelays: _relayUrls.toList()),
      );
      Logger.setLogLevel(ll.Level.warning);
      return;
    }

    pool = WebSocketPool(_relayUrls);

    _sub = pool!.stream.listen((record) {
      final (relayUrl, data) = record;
      final [type, subscriptionId, ...rest] = jsonDecode(data) as List;

      try {
        switch (type) {
          case 'EVENT':
            final Map<String, dynamic> map = rest.first;
            // If collecting events for EOSE, do not attempt to verify here
            if (_resultsOnEose.containsKey((relayUrl, subscriptionId))) {
              _resultsOnEose[(relayUrl, subscriptionId)]!.add(map);
              return;
            }

            final alreadyVerified = _isEventVerified?.call(map) ?? false;
            if (alreadyVerified || _verifyEvent(map)) {
              state = EventRelayMessage(
                relayUrl: relayUrl,
                event: map,
                subscriptionId: subscriptionId,
              );
            }
            break;
          case 'NOTICE':
            if (_errorRegex.hasMatch(subscriptionId)) {
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
            if (_resultsOnEose.containsKey((relayUrl, subscriptionId))) {
              final incomingEvents =
                  _resultsOnEose.remove((relayUrl, subscriptionId))!;
              _verifyEventsAsync(incomingEvents,
                      isEventVerified: _isEventVerified)
                  .then((events) {
                state = EoseWithEventsRelayMessage(
                  relayUrl: relayUrl,
                  events: events,
                  subscriptionId: subscriptionId,
                );
              });
            } else {
              state = EoseRelayMessage(
                relayUrl: relayUrl,
                subscriptionId: subscriptionId,
              );
            }
            break;
          case 'OK':
            state = PublishedEventRelayMessage(
              relayUrl: relayUrl,
              subscriptionId: subscriptionId,
              accepted: rest.first as bool,
              message: rest.lastOrNull?.toString(),
            );
            break;
        }
      } catch (err) {
        state = ErrorRelayMessage(
            relayUrl: relayUrl, subscriptionId: null, error: err.toString());
        _sub?.cancel();
        _streamSub?.cancel();
        _closeFns[subscriptionId]?.call();
      }
    });
  }

  RelayMessage get relayMessage => super.state;

  void configure({bool Function(Map<String, dynamic> event)? isEventVerified}) {
    _isEventVerified ??= isEventVerified;
  }

  NdkResponse? response;

  void addRequest(RelayRequest req) {
    _requests.add(req);
    pool!.send(jsonEncode(["REQ", req.subscriptionId, req.toMap()]));
  }

  Future<List<Map<String, dynamic>>> queryRaw(RelayRequest req) async {
    if (ndk != null) {
      final response = ndk!.requests.query(
        filters: [Filter.fromMap(req.toMap())],
      );
      final events = await response.future;
      return events.map((e) => e.toJson()).toList();
    }

    final completer = Completer<List<Map<String, dynamic>>>();

    final relayUrls = pool!.relayUrls;
    final allEvents = <Map<String, dynamic>>[];
    final eoses = <String, bool>{for (final r in relayUrls) r: false};

    _closeFns[req.subscriptionId] = addListener((message) {
      if (message.subscriptionId != req.subscriptionId) return;
      switch (message) {
        case EoseWithEventsRelayMessage(:final events, :final relayUrl):
          eoses[relayUrl!] = true;
          for (final event in events) {
            if (!allEvents.any((e) => e['id'] == event['id'])) {
              allEvents.add(event);
            }
          }
          // If there are at least as much EOSEs as connected relays, we're good
          final enoughEoses = eoses.values.where((v) => v).length >=
              pool!.connectedRelayUrls.length;
          if (enoughEoses && !completer.isCompleted) {
            final allEventsSorted = allEvents.sortedByCompare(
                (m) => m['created_at'] as int, (a, b) => b.compareTo(a));
            completer.complete(allEventsSorted);
            scheduleMicrotask(() {
              _closeFns[req.subscriptionId]?.call();
            });
          }
          break;
        case ErrorRelayMessage(:final error):
          completer.completeError(Exception(error));
          break;
        default:
      }
    }, fireImmediately: false);

    addRequest(req);
    for (final relayUrl in relayUrls) {
      _resultsOnEose[(relayUrl, req.subscriptionId)] = [];
    }

    return completer.future;
  }

  Future<List<E>> query<E extends Event<E>>(
      {Set<String>? ids,
      Set<String>? authors,
      Map<String, dynamic>? tags,
      String? search,
      DateTime? since,
      DateTime? until,
      int? limit,
      Iterable<String>? relayUrls}) async {
    final req = RelayRequest(
        kinds: {Event.types[E.toString()]!.kind},
        ids: ids ?? {},
        authors: authors ?? {},
        tags: tags ?? {},
        search: search,
        since: since,
        until: until,
        limit: limit);

    final result = await queryRaw(req);
    return result.map(Event.getConstructor<E>()!.call).toList();
  }

  Future<void> publish(Event event) async {
    final completer = Completer<void>();

    if (ndk != null) {
      final response = ndk!.broadcast.broadcast(
        nostrEvent: Nip01Event.fromJson(event.toMap()),
        specificRelays: ndk!.relays.connectedRelays.map((rc) => rc.url),
      );
      final relayResponses = await response.broadcastDoneFuture;
      final firstRelayError =
          relayResponses.firstWhereOrNull((r) => !r.broadcastSuccessful);

      if (firstRelayError != null) {
        completer.completeError(Exception(firstRelayError.msg));
      } else {
        completer.complete();
      }
      return;
    }

    pool!.send(jsonEncode(["EVENT", event.toMap()]));

    _closeFns[event.event.id.toString()] = addListener((message) {
      if (message.subscriptionId != null &&
          event.event.id.toString() != message.subscriptionId) {
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

  @override
  Future<void> dispose() async {
    if (ndk != null) {
      await ndk!.destroy();
      return;
    }

    for (final closeFn in _closeFns.values) {
      closeFn.call();
    }
    await pool!.close();
    _sub?.cancel();
    _streamSub?.cancel();
    if (mounted) {
      super.dispose();
    }
  }

  // Event validation

  static Future<List<Map<String, dynamic>>> _verifyEventsAsync(
      List<Map<String, dynamic>> incomingEvents,
      {bool Function(Map<String, dynamic> event)? isEventVerified}) async {
    if (incomingEvents.isEmpty) return [];

    final unverifiedEvents = isEventVerified != null
        ? incomingEvents.whereNot(isEventVerified).toList()
        : incomingEvents;

    if (unverifiedEvents.isNotEmpty) {
      final notVerifiedEvents = await Isolate.run(
          () => unverifiedEvents.whereNot(_verifyEvent).toList());
      for (final nve in notVerifiedEvents) {
        incomingEvents.remove(nve);
      }
    }
    return incomingEvents;
  }

  static bool _verifyEvent(Map<String, dynamic> map) {
    return bip340.verify(map['pubkey'], map['id'], map['sig']);
  }
}

final random = Random();

class RelayRequest extends Equatable {
  late final String subscriptionId;
  final Set<String> ids;
  final Set<int> kinds;
  final Set<String> authors;
  final Map<String, dynamic> tags;
  final String? search;
  final DateTime? since;
  final DateTime? until;
  final int? limit;

  RelayRequest({
    this.ids = const {},
    this.kinds = const {},
    this.authors = const {},
    this.tags = const {},
    this.search,
    this.since,
    this.until,
    this.limit,
  }) {
    subscriptionId = 'sub-${random.nextInt(999999)}';
  }

  Map<String, dynamic> toMap() {
    return {
      if (ids.isNotEmpty) 'ids': ids.toList(),
      if (kinds.isNotEmpty) 'kinds': kinds.toList(),
      if (authors.isNotEmpty) 'authors': authors.toList(),
      for (final e in tags.entries)
        e.key: e.value is Iterable ? e.value.toList() : e.value,
      if (since != null) 'since': since!.toInt(),
      if (until != null) 'until': until!.toInt(),
      if (limit != null) 'limit': limit,
      if (search != null) 'search': search,
    };
  }

  @override
  List<Object?> get props => [toMap()];

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

class EoseWithEventsRelayMessage extends RelayMessage {
  final List<Map<String, dynamic>> events;

  EoseWithEventsRelayMessage({
    super.relayUrl,
    required super.subscriptionId,
    required this.events,
  });

  @override
  String toString() {
    return '${super.toString()}: ${events.length}';
  }
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
