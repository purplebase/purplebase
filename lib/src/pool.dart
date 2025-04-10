import 'dart:async';
import 'dart:convert';
import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:web_socket_client/web_socket_client.dart';

class WebSocketPool
    extends StateNotifier<(List<Map<String, dynamic>>, ResponseMetadata)?> {
  final Ref ref;
  final WebSocketClient _webSocketClient;
  final PurplebaseStorageConfiguration config;

  WebSocketPool(this.ref)
    : _webSocketClient = ref.read(webSocketClientProvider),
      config = ref.read(purplebaseConfigurationProvider),
      super(null) {
    // Ensure we're listening to messages
    _initMessageListener();
  }

  // Map of relay URLs to their idle timers
  final Map<String, Timer> _idleTimers = {};

  /// Map to track batched events before EOSE per subscription and relay (uses [ResponseMetadata])
  final Map<ResponseMetadata, List<Map<String, dynamic>>> _preEoseBatches = {};

  // Buffer for post-EOSE streaming events
  final Map<ResponseMetadata, List<Map<String, dynamic>>> _streamingBuffer = {};

  // Timers for flushing the streaming buffer
  final Map<ResponseMetadata, Timer> _streamingBufferTimers = {};

  // Subscription tracking which relays have sent EOSE
  final List<ResponseMetadata> _eoseReceivedFrom = [];

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
    // print('socket listening');
    _messagesSubscription ??= _webSocketClient.messages.listen((m) {
      // print('receiving message $m');
      _handleMessage(m);
    });
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

      final r = ResponseMetadata(
        subscriptionId: req.subscriptionId,
        relayUrls: {url},
      );
      _preEoseBatches[r] = [];
      _streamingBuffer[r] = [];

      // Create and send the REQ message with the optimized filter
      final reqMsg = _createReqMessage(optimizedReq);
      // print('socket sending $reqMsg');
      _webSocketClient.send(reqMsg);

      // Reset the idle timer
      _resetIdleTimer(url);
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

  // Create a Nostr REQ message
  String _createReqMessage(RequestFilter filter) {
    return jsonEncode(['REQ', filter.subscriptionId, filter.toMap()]);
  }

  // Ensure a connection to a relay is established
  Future<void> _ensureConnected(String url) async {
    if (!_connectedRelays.contains(url)) {
      final uri = Uri.parse(url);
      // print('socket connecting');
      await _webSocketClient.connect(uri);
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
  void _handleMessage((String relayUrl, String message) data) {
    final (relayUrl, message) = data;
    try {
      final List parsed = jsonDecode(message);
      if (parsed.isEmpty) return;

      final String messageType = parsed[0];

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

      final r = ResponseMetadata(
        subscriptionId: subscriptionId,
        relayUrls: {relayUrl},
      );

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
          state = ([...events], r);
          _streamingBuffer[r]!.clear();
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
    // TODO: This in sqlite
    // final req = RequestFilter();
    // // For non-time-windowed requests, save timestamp
    // if (req.since == null &&
    //     req.until == null &&
    //     map['created_at'] is int) {
    //   final r = '${req.hash}:$relayUrl';
    //   db.execute(
    //     'INSERT OR REPLACE INTO requests (request, until) VALUES (?, ?)',
    //     [r, map['created_at']],
    //   );
    //   print('q with $r ${map['created_at']}');
    // }

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
  void _handleEoseMessage(List<dynamic> parsed, String relayUrl) {
    if (parsed case [
      _,
      final subscriptionId,
    ] when _subscriptionExists(subscriptionId)) {
      // Mark that we've received EOSE for this subscription from this relay
      final r = ResponseMetadata(
        subscriptionId: subscriptionId,
        relayUrls: {relayUrl},
      );
      _eoseReceivedFrom.add(r);

      // Emit pre-EOSE batch for this relay
      if (_preEoseBatches[r] != null && _preEoseBatches[r]!.isNotEmpty) {
        final events = _preEoseBatches[r]!;
        // print('sending state (pre eose): $events - $r');
        state = ([...events], r);
        _preEoseBatches[r]!.clear();
      }
    }
  }

  // Unsubscribe from a subscription
  void unsubscribe(String subscriptionId) {
    if (_subscriptionExists(subscriptionId)) {
      final closeMsg = jsonEncode(['CLOSE', subscriptionId]);

      // Send CLOSE message
      // print('socket sending close $closeMsg');
      _webSocketClient.send(closeMsg);

      // Clean up subscription data
      _subscriptions.remove(subscriptionId);
      _preEoseBatches.removeWhere((r, _) => r.subscriptionId == subscriptionId);
      _streamingBuffer.removeWhere(
        (r, _) => r.subscriptionId == subscriptionId,
      );
      _eoseReceivedFrom.removeWhere((r) => r.subscriptionId == subscriptionId);
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
    // print('socket closing');
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
  final Map<String, bool> _connectionStatus = {};

  Future<void> connect(Uri uri) async {
    if (!_sockets.containsKey(uri)) {
      final socket = WebSocket(uri);
      _sockets[uri] = socket;
      _connectionStatus[uri.toString()] = true;

      // Setup listeners for this socket
      socket.messages.listen((message) {
        if (message is String) {
          _messagesController.add((uri.toString(), message));
        }
      });

      socket.connection.listen((state) {
        if (state is Disconnected) {
          _connectionStatus[uri.toString()] = false;
        } else if (state is Connected) {
          _connectionStatus[uri.toString()] = true;
        }
      });
    }
    return Future.value();
  }

  void send(String message) {
    // Send to all connected sockets
    for (final entry in _sockets.entries) {
      final uri = entry.key;
      final socket = entry.value;
      final url = uri.toString();

      if (_connectionStatus[url] == true) {
        socket.send(message);
      }
    }
  }

  void close() {
    // Close all sockets
    for (final socket in _sockets.values) {
      socket.close();
    }
    _sockets.clear();

    // Set all connections to false
    for (final url in _connectionStatus.keys) {
      _connectionStatus[url] = false;
    }
  }

  Stream<(String relayUrl, String message)> get messages =>
      _messagesController.stream;

  bool get isConnected =>
      _connectionStatus.values.any((connected) => connected);
}

// Provider for NostrWebSocketClient
final webSocketClientProvider = Provider<WebSocketClient>((ref) {
  return WebSocketClient();
});

// Provider for WebsocketPool
final webSocketPoolProvider = StateNotifierProvider<
  WebSocketPool,
  (List<Map<String, dynamic>>, ResponseMetadata)?
>(WebSocketPool.new);
