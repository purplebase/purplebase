import 'dart:async';
import 'dart:convert';
import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:web_socket_client/web_socket_client.dart';

class WebSocketPool
    extends StateNotifier<(RequestFilter, List<Map<String, dynamic>>)?> {
  final Ref ref;
  final WebSocketClient _webSocketClient;
  final PurplebaseConfiguration config;

  WebSocketPool(this.ref)
    : _webSocketClient = ref.read(webSocketClientProvider),
      config = ref.read(purplebaseConfigurationProvider),
      super(null);

  // Map of relay URLs to their idle timers
  final Map<String, Timer> _idleTimers = {};

  // Map of subscription IDs to their RequestFilters
  final Map<String, RequestFilter> _subscriptions = {};

  // Map to track batched events before EOSE per subscription and relay
  final Map<String, Map<String, List<Map<String, dynamic>>>> _preEoseBatches =
      {};

  // Buffer for post-EOSE streaming events
  final Map<String, List<Map<String, dynamic>>> _streamingBuffer = {};

  // Subscription tracking which relays have sent EOSE
  final Map<String, Set<String>> _eoseReceivedFrom = {};

  // Map to track latest timestamp per (RequestFilter, relayUrl) combination
  final Map<(String, String), DateTime?> _latestTimestamps = {};

  // Set to track event IDs we've already seen to avoid duplicates
  final Map<String, Set<String>> _seenEventIds = {};

  // Set of connected relays
  final Set<String> _connectedRelays = {};

  // Timer for flushing the streaming buffer
  Timer? _streamingTimer;

  // Subscription for the messages stream
  StreamSubscription? _messagesSubscription;

  // Initialize the message listener
  void _initMessageListener() {
    _messagesSubscription?.cancel();
    _messagesSubscription = _webSocketClient.messages.listen(_handleMessage);
  }

  // Send a request to relays
  Future<void> send(RequestFilter req, {Set<String>? relayUrls}) async {
    final urls = relayUrls ?? _connectedRelays;
    if (urls.isEmpty) {
      return;
    }

    // Store the subscription
    _subscriptions[req.subscriptionId] = req;

    // Initialize tracking for this subscription
    _preEoseBatches[req.subscriptionId] = {};
    _eoseReceivedFrom[req.subscriptionId] = {};
    _seenEventIds[req.subscriptionId] = {};

    // Reset state for new filter
    print('resetting state for filter $req');
    state = (req, []);

    // Ensure we're listening to messages
    _initMessageListener();

    // Send to each relay with optimized filters
    for (final url in urls) {
      // Apply timestamp optimization for this combination
      final optimizedReq = _optimizeRequestFilter(req, url);

      await _ensureConnected(url);
      _preEoseBatches[req.subscriptionId]![url] = [];

      // Create and send the REQ message with the optimized filter
      final reqMsg = _createReqMessage(optimizedReq);
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
        _webSocketClient.close();
      }

      _idleTimers.remove(url);
    }
  }

  // Handle incoming messages with relay URL
  void _handleMessage((String relayUrl, String message) data) {
    final (relayUrl, message) = data;
    try {
      final List<dynamic> parsed = jsonDecode(message);
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
    if (parsed.length < 3) return;

    final [_, String subId, Map<String, dynamic> event] = parsed;

    print('receiving event for $subId');

    // Skip if we don't have this subscription
    if (!_subscriptions.containsKey(subId)) return;

    // Check if this event has an ID
    if (!event.containsKey('id')) return;

    // Check if we've already seen this event
    final String eventId = event['id'];
    if (_seenEventIds.containsKey(subId) &&
        _seenEventIds[subId]!.contains(eventId)) {
      // Skip this event as it's a duplicate
      return;
    }

    // Mark this event as seen
    _seenEventIds[subId] ??= {};
    _seenEventIds[subId]!.add(eventId);

    // Update the latest timestamp for this (filter, relay) combination if newer
    _updateLatestTimestamp(subId, relayUrl, event);

    // Check if we've received EOSE for this subscription from this relay
    if (_eoseReceivedFrom.containsKey(subId) &&
        _eoseReceivedFrom[subId]!.contains(relayUrl)) {
      // Post-EOSE (streaming) - add to streaming buffer
      if (!_streamingBuffer.containsKey(subId)) {
        _streamingBuffer[subId] = [];
      }
      _streamingBuffer[subId]!.add(event);

      // Start the streaming timer if not already running
      _ensureStreamingTimerActive();
    } else {
      // Pre-EOSE - add to pre-EOSE batch
      if (_preEoseBatches.containsKey(subId) &&
          _preEoseBatches[subId]!.containsKey(relayUrl)) {
        _preEoseBatches[subId]![relayUrl]!.add(event);
      }
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
      final int timestamp = event['created_at'];
      final DateTime eventTime = DateTime.fromMillisecondsSinceEpoch(
        timestamp * 1000,
      );

      // Get the current latest timestamp
      final currentLatest = _latestTimestamps[(subId, relayUrl)];

      // Update if this is newer
      if (currentLatest == null || eventTime.isAfter(currentLatest)) {
        _latestTimestamps[(subId, relayUrl)] = eventTime;
      }
    }
  }

  // Handle EOSE (End of Stored Events) messages
  void _handleEoseMessage(List<dynamic> parsed, String relayUrl) {
    if (parsed.length < 2) return;

    final [_, String subId] = parsed;

    // Skip if we don't have this subscription
    if (!_subscriptions.containsKey(subId)) return;
    final filter = _subscriptions[subId]!;

    // Mark that we've received EOSE for this subscription from this relay
    if (!_eoseReceivedFrom.containsKey(subId)) {
      _eoseReceivedFrom[subId] = {};
    }
    _eoseReceivedFrom[subId]!.add(relayUrl);

    // Emit pre-EOSE batch for this relay
    if (_preEoseBatches.containsKey(subId) &&
        _preEoseBatches[subId]!.containsKey(relayUrl) &&
        _preEoseBatches[subId]![relayUrl]!.isNotEmpty) {
      final batch = _preEoseBatches[subId]![relayUrl]!;
      if (batch.isNotEmpty) {
        _emitEvents(filter, batch);
        _preEoseBatches[subId]![relayUrl] = [];
      }
    }
  }

  // Emit events with their associated filter, with deduplication
  void _emitEvents(RequestFilter filter, List<Map<String, dynamic>> newEvents) {
    if (state == null || filter.subscriptionId != state!.$1.subscriptionId) {
      // If it's a different filter than the current one, just replace state
      print('different, replace state event # ${newEvents.length}');
      state = (filter, newEvents);
    } else {
      // Append to existing events for the same filter, but avoid duplicates
      final existingEvents = state!.$2;

      // Create a set of IDs from existing events for efficient lookup
      final existingIds =
          existingEvents
              .where((e) => e.containsKey('id'))
              .map((e) => e['id'] as String)
              .toSet();

      // Filter out events that already exist in the state
      final uniqueNewEvents =
          newEvents
              .where(
                (event) =>
                    event.containsKey('id') &&
                    !existingIds.contains(event['id']),
              )
              .toList();

      // Only update state if we have new unique events
      if (uniqueNewEvents.isNotEmpty) {
        print('emitting ${uniqueNewEvents.length} new events');
        state = (filter, [...existingEvents, ...uniqueNewEvents]);
      }
    }
  }

  // Ensure the streaming timer is active
  void _ensureStreamingTimerActive() {
    _streamingTimer?.cancel();
    _streamingTimer = Timer(
      config.streamingBufferWindow,
      _flushStreamingBuffer,
    );
  }

  // Flush the streaming buffer
  void _flushStreamingBuffer() {
    if (_streamingBuffer.isEmpty) return;

    // Process each subscription's events
    for (final entry in _streamingBuffer.entries) {
      final subId = entry.key;
      final events = entry.value;

      if (events.isNotEmpty && _subscriptions.containsKey(subId)) {
        final filter = _subscriptions[subId]!;
        _emitEvents(filter, events);
      }
    }

    _streamingBuffer.clear();
  }

  // Unsubscribe from a subscription
  void unsubscribe(String subscriptionId) {
    if (_subscriptions.containsKey(subscriptionId)) {
      final closeMsg = jsonEncode(['CLOSE', subscriptionId]);

      // Send CLOSE message
      _webSocketClient.send(closeMsg);

      // Clean up subscription data
      _subscriptions.remove(subscriptionId);
      _preEoseBatches.remove(subscriptionId);
      _eoseReceivedFrom.remove(subscriptionId);
      _streamingBuffer.remove(subscriptionId);
      _seenEventIds.remove(subscriptionId);
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
    _streamingTimer?.cancel();

    // Close the client
    _webSocketClient.close();

    // Clear all tracking maps
    _seenEventIds.clear();

    super.dispose();
  }
}

// Interface for WebSocket functionality needed in WebsocketPool
// abstract class NostrWebSocketClient {
//   Future<void> connect(Uri uri);
//   void send(String message);
//   void close();
//   Stream<(String relayUrl, String message)> get messages;
//   bool get isConnected;
// }

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
final websocketPoolProvider = StateNotifierProvider<
  WebSocketPool,
  (RequestFilter, List<Map<String, dynamic>>)?
>(WebSocketPool.new);
