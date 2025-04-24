import 'dart:async';
import 'dart:convert';
import 'package:models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:web_socket_client/web_socket_client.dart';

class WebSocketPool
    extends StateNotifier<(List<Map<String, dynamic>>, (String, String))?> {
  final Ref ref;
  final WebSocketClient _webSocketClient;
  final StorageConfiguration config;

  WebSocketPool(this.ref, this.config)
    : _webSocketClient = ref.read(webSocketClientProvider),
      super(null) {
    // Ensure we're listening to messages
    _initMessageListener();
  }

  // Map of relay URLs to their idle timers
  final Map<String, Timer> _idleTimers = {};

  /// Map to track batched events before EOSE per subscription and relay
  final Map<(String, String), List<Map<String, dynamic>>> _preEoseBatches = {};

  // Buffer for post-EOSE streaming events
  final Map<(String, String), List<Map<String, dynamic>>> _streamingBuffer = {};

  // Timers for flushing the streaming buffer
  final Map<(String, String), Timer> _streamingBufferTimers = {};

  // Subscription tracking which relays have sent EOSE
  final List<(String, String)> _eoseReceivedFrom = [];

  final List<String> _seenEventIds = [];

  final List<String> _subscriptions = [];

  bool _subscriptionExists(String subscriptionId) {
    return _subscriptions.contains(subscriptionId);
  }

  // Map to track latest timestamp per (RequestFilter, relayUrl) combination
  final Map<(String, String), DateTime?> _latestTimestamps = {};

  // Set of connected relays
  final Set<String> _connectedRelays = {};

  // Subscription for the messages stream
  StreamSubscription? _messagesSubscription;

  // Initialize the message listener
  void _initMessageListener() {
    print('socket listening');
    _messagesSubscription ??= _webSocketClient.messages.listen(_handleMessage);
  }

  // Send a request to relays
  Future<void> send(RequestFilter req, {Set<String>? relayUrls}) async {
    final urls = relayUrls ?? _connectedRelays;
    if (urls.isEmpty) {
      return;
    }

    _subscriptions.add(req.subscriptionId);

    // Send to each relay with optimized filters
    for (final url in urls) {
      // Apply timestamp optimization for this combination
      final optimizedReq = _optimizeRequestFilter(req, url);

      await _ensureConnected(url);

      final r = (req.subscriptionId, url);
      _preEoseBatches[r] = [];
      _streamingBuffer[r] = [];

      // Create and send the REQ message with the optimized filter
      final reqMsg = jsonEncode([
        'REQ',
        optimizedReq.subscriptionId,
        optimizedReq.toMap(),
      ]);
      print('socket sending $reqMsg');
      _webSocketClient.send(reqMsg);

      // Reset the idle timer
      _resetIdleTimer(url);
    }
  }

  // Publish an event to relays
  // TODO: Should check if it was accepted or not
  Future<void> publish(
    List<Map<String, dynamic>> events, {
    Set<String>? relayUrls,
  }) async {
    for (final event in events) {
      _webSocketClient.send(jsonEncode(["EVENT", event]), relayUrls: relayUrls);
    }
  }

  // Optimize request filter based on latest seen timestamp
  RequestFilter _optimizeRequestFilter(RequestFilter filter, String relayUrl) {
    // Previous code

    // TODO: This in sqlite
    // First caching layer: ids
    // if (req.ids.isNotEmpty) {
    //   final (idsSql, idsParams) = RequestFilter(
    //     ids: req.ids,
    //   ).toSQL(returnIds: true);
    //   final storedIds = await _isolateManager.query(idsSql, [idsParams]);
    //   // Modify req to only query for ids that are not in local storage
    //   req = req.copyWith(
    //     ids: req.ids.difference(storedIds.map((e) => e['id']!).toSet()),
    //   );
    // }

    // final r = '${req.hash}:RELAY_URL';
    // final result = await _isolateManager.query(
    //   'SELECT until from requests WHERE request = :r',
    //   [
    //     {':r': r},
    //   ],
    // );

    // if (result.isNotEmpty) {
    //   req = req.copyWith(since: (result.first['until'] as int).toDate());
    // }

    // print(req.toMap());
    // print(req.hash);

    // Check if we have a latest timestamp for this combination
    final latestTimestamp =
        _latestTimestamps[(filter.subscriptionId, relayUrl)];

    // If we have a timestamp and the original filter doesn't have a more recent since value
    if (latestTimestamp != null &&
        (filter.since == null || filter.since!.isBefore(latestTimestamp))) {
      // Create a new filter with the updated since value
      return RequestFilter(
        subscriptionId: filter.subscriptionId,
        ids: filter.ids,
        authors: filter.authors,
        kinds: filter.kinds,
        tags: filter.tags,
        search: filter.search,
        since: latestTimestamp,
        until: filter.until,
        limit: filter.limit,
      );
    }

    // Return the original filter if no optimization needed
    return filter;
  }

  // TODO: Its not ensure, it just connects and queues
  Future<void> _ensureConnected(String url) async {
    if (!_connectedRelays.contains(url)) {
      final uri = Uri.parse(url);
      // print('socket connecting $url');
      _webSocketClient.connect(uri);
      _connectedRelays.add(url);
    }
  }

  // Reset the idle timer for a relay
  void _resetIdleTimer(String url) {
    _idleTimers[url]?.cancel();
    _idleTimers[url] = Timer(config.idleTimeout, () => _disconnectRelay(url));
  }

  // Disconnect from a relay
  void _disconnectRelay(String url) {
    if (_connectedRelays.contains(url)) {
      _connectedRelays.remove(url);

      // If no more connected relays, we can close the client
      if (_connectedRelays.isEmpty) {
        // print('socket closing');
        _webSocketClient.close();
      }

      _idleTimers.remove(url);
    }
  }

  // Handle incoming messages with relay URL
  void _handleMessage(data) {
    if (data case (final String relayUrl, final message)) {
      // print('received from $relayUrl');
      try {
        final parsed = jsonDecode(message) as List;
        if (parsed.isEmpty) return;

        final [messageType, ..._] = parsed;

        switch (messageType) {
          case 'EVENT':
            _handleEventMessage(parsed, relayUrl);
            break;
          case 'EOSE':
            _handleEoseMessage(parsed, relayUrl);
            break;
          case 'NOTICE':
            // Handle notices if needed
            break;
          case 'OK':
            // Handle OK messages if needed
            break;
        }

        // Reset idle timer as we received a message
        _resetIdleTimer(relayUrl);
      } catch (e) {
        print('Error handling message: $e');
      }
    }
  }

  // Handle EVENT messages
  void _handleEventMessage(List<dynamic> parsed, String relayUrl) {
    if (parsed case [
      _,
      final String subscriptionId,
      final Map<String, dynamic> event,
    ] when _subscriptionExists(subscriptionId)) {
      // Check if this event has an ID
      if (!event.containsKey('id')) return;

      final eventId = event['id'].toString();

      final r = (subscriptionId, relayUrl);

      // Update the latest timestamp for this (filter, relay) combination if newer
      _updateLatestTimestamp(subscriptionId, relayUrl, event);

      // Check if we've received EOSE for this subscription from this relay
      if (_eoseReceivedFrom.contains(r)) {
        // Post-EOSE (streaming) - add to streaming buffer
        _streamingBuffer[r] ??= [];
        if (_seenEventIds.contains(eventId)) {
          // Add an ID-map to signal upstream that the event
          // was already saved, and only needs a seen relay update
          _streamingBuffer[r]!.add({'id': eventId});
        } else {
          _streamingBuffer[r]!.add(event);
        }

        // Start the streaming timer if not already running
        _streamingBufferTimers[r] ??= Timer(config.streamingBufferWindow, () {
          final events = _streamingBuffer[r]!;
          // print('setting state (streaming flush): $events');
          state = ([...events], (relayUrl, subscriptionId));
          _streamingBuffer[r]!.clear();
          _streamingBufferTimers.remove(r);
        });
      } else {
        // Pre-EOSE - add to pre-EOSE batch
        _preEoseBatches[r] ??= [];

        if (_seenEventIds.contains(eventId)) {
          // Add an ID-map to signal upstream that the event
          // was already saved, and only needs a seen relay update
          _preEoseBatches[r]!.add({'id': eventId});
        } else {
          _preEoseBatches[r]!.add(event);
        }
      }

      // Mark this event as seen
      _seenEventIds.add(eventId);
    }
  }

  // Update the latest timestamp for a (filter, relay) combination
  void _updateLatestTimestamp(
    String subId,
    String relayUrl,
    Map<String, dynamic> event,
  ) {
    // TODO: Implement properly

    // Check if the event has a created_at timestamp
    if (event.containsKey('created_at')) {
      final timestamp = event['created_at'];
      final eventTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);

      // Get the current latest timestamp
      final currentLatest = _latestTimestamps[(subId, relayUrl)];

      // Update if this is newer
      if (currentLatest == null || eventTime.isAfter(currentLatest)) {
        _latestTimestamps[(subId, relayUrl)] = eventTime;
      }
    }
  }

  // Handle EOSE messages
  void _handleEoseMessage(List parsed, String relayUrl) {
    if (parsed case [
      _,
      final String subscriptionId,
    ] when _subscriptionExists(subscriptionId)) {
      // Mark that we've received EOSE for this subscription from this relay
      final r = (subscriptionId, relayUrl);
      _eoseReceivedFrom.add(r);

      // Emit pre-EOSE batch for this relay
      if (_preEoseBatches[r] != null && _preEoseBatches[r]!.isNotEmpty) {
        final events = _preEoseBatches[r]!;
        // print('sending state (pre eose): $events - $r');
        state = ([...events], (relayUrl, subscriptionId));
        _preEoseBatches[r]!.clear();
      }
    }
  }

  // Unsubscribe from a subscription
  void unsubscribe(String subscriptionId) {
    if (_subscriptionExists(subscriptionId)) {
      final closeMsg = jsonEncode(['CLOSE', subscriptionId]);

      // Send CLOSE message
      print('socket sending close $closeMsg');
      _webSocketClient.send(closeMsg);

      // Clean up subscription data
      _subscriptions.remove(subscriptionId);
      _preEoseBatches.removeWhere((r, _) => r.$1 == subscriptionId);
      _streamingBuffer.removeWhere((r, _) => r.$1 == subscriptionId);
      _eoseReceivedFrom.removeWhere((r) => r.$1 == subscriptionId);
    }
  }

  // Cleanup resources when the notifier is disposed
  @override
  void dispose() {
    _messagesSubscription?.cancel();

    // Cancel all timers
    for (final timer in _idleTimers.values) {
      timer.cancel();
    }
    for (final timer in _streamingBufferTimers.values) {
      timer.cancel();
    }

    // Close the client
    print('socket closing');
    _webSocketClient.close();

    // Clear maps
    _subscriptions.clear();
    _preEoseBatches.clear();
    _streamingBuffer.clear();
    _eoseReceivedFrom.clear();
    _seenEventIds.clear();

    super.dispose();
  }
}

class WebSocketClient {
  final Map<Uri, WebSocket> _sockets = {};
  final StreamController<(String relayUrl, String message)>
  _messagesController =
      StreamController<(String relayUrl, String message)>.broadcast();
  final _subs = <StreamSubscription>{};
  final _queue = <Uri, List<String>>{};

  void connect(Uri uri) {
    if (!_sockets.containsKey(uri)) {
      final socket = WebSocket(uri);
      _sockets[uri] = socket;

      // Setup listeners for this socket
      _subs.add(
        socket.messages.listen((message) {
          _messagesController.add((uri.toString(), message));
        }),
      );

      _subs.add(
        socket.connection.listen((state) {
          switch (state) {
            case Connected() || Reconnected():
              while (_queue[uri]?.isNotEmpty ?? false) {
                _sockets[uri]!.send(_queue[uri]!.removeAt(0));
              }
            case _:
            // TODO: Reconnection logic, re-request events since connection dropped
          }
        }),
      );
    }
  }

  void send(String message, {Set<String>? relayUrls}) {
    // Send to all connected sockets
    for (final MapEntry(key: uri, value: client) in _sockets.entries) {
      if (relayUrls != null && !relayUrls.contains(uri.toString())) {
        // If relayUrls specified but this relay not there, skip
        continue;
      }
      _queue[uri] ??= [];
      switch (client.connection.state) {
        case Connected() || Reconnected():
          print(
            '[${DateTime.now().toIso8601String()}] Sending req to $uri: $message',
          );
          client.send(message);
        case _:
          print('[${DateTime.now().toIso8601String()}] QUEUING req to $uri');
          if (!_queue[uri]!.contains(message)) {
            _queue[uri]!.add(message);
          }
      }
    }
  }

  void close() {
    for (final socket in _sockets.values) {
      socket.close(1000, 'CLOSE_NORMAL');
    }
    _sockets.clear();
  }

  Stream<(String relayUrl, String message)> get messages =>
      _messagesController.stream;
}

final webSocketClientProvider = Provider<WebSocketClient>((ref) {
  return WebSocketClient();
});
