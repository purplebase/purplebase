import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:web_socket_client/web_socket_client.dart';

enum SubscriptionPhase {
  initial, // Waiting for EOSE
  streaming, // After EOSE received
}

class SubscriptionState {
  final RequestFilter filter;
  final Set<String> targetRelays;
  final Set<String> connectedRelays;
  final Set<String> eoseReceived;
  final List<Map<String, dynamic>> bufferedEvents;
  SubscriptionPhase phase;
  Timer? streamingBuffer;
  Timer? eoseTimeoutTimer; // Add timeout timer for EOSE waiting
  DateTime? lastEventTime;
  Completer<List<Map<String, dynamic>>>? queryCompleter; // For query() method

  SubscriptionState({required this.filter, required this.targetRelays})
    : connectedRelays = <String>{},
      eoseReceived = <String>{},
      bufferedEvents = <Map<String, dynamic>>[],
      phase = SubscriptionPhase.initial;

  bool get allEoseReceived =>
      targetRelays.isEmpty || eoseReceived.containsAll(targetRelays);
}

class RelayState {
  WebSocket? socket;
  DateTime? lastActivity;
  DateTime? firstFailureTime;
  int reconnectAttempts;
  Timer? reconnectTimer;
  Timer? idleTimer;
  bool isDead;
  StreamSubscription? connectionSubscription;
  StreamSubscription? messageSubscription;

  RelayState() : reconnectAttempts = 0, isDead = false;

  /// Use the underlying socket's actual connection state
  bool get isConnected {
    if (socket == null || isDead) return false;
    final connectionState = socket!.connection.state;
    return connectionState is Connected || connectionState is Reconnected;
  }

  bool get isConnecting {
    if (socket == null || isDead) return false;
    final connectionState = socket!.connection.state;
    return connectionState is Connecting || connectionState is Reconnecting;
  }

  bool get isDisconnected {
    if (socket == null || isDead) return true;
    final connectionState = socket!.connection.state;
    return connectionState is Disconnected || connectionState is Disconnecting;
  }

  /// Check if socket is in a state where we should attempt reconnection
  bool get shouldReconnect {
    if (socket == null || isDead) return !isDead;
    final connectionState = socket!.connection.state;
    return connectionState is Disconnected && !isDead;
  }
}

class WebSocketPool extends StateNotifier<List<RelayResponse>?> {
  final Map<String, RelayState> _relays = {};
  final Map<String, SubscriptionState> _subscriptions = {};
  final Map<String, Set<String>> _seenEventRelays =
      {}; // Track which relays sent each event
  final Duration _idleTimeout;
  final Duration _streamingBufferTimeout;
  bool _disposed = false;

  WebSocketPool({Duration? idleTimeout, Duration? streamingBufferTimeout})
    : _idleTimeout = idleTimeout ?? const Duration(minutes: 5),
      _streamingBufferTimeout =
          streamingBufferTimeout ?? const Duration(seconds: 2),
      super(null);

  /// Asynchronously closes all connections and cleans up resources
  Future<void> disposeAsync() async {
    if (_disposed) return;
    _disposed = true;

    // Cancel all subscriptions and timers first
    for (final subscription in _subscriptions.values) {
      subscription.streamingBuffer?.cancel();
      subscription.eoseTimeoutTimer?.cancel();
      // Complete any pending query completers to prevent hanging
      if (subscription.queryCompleter != null &&
          !subscription.queryCompleter!.isCompleted) {
        subscription.queryCompleter!.complete([]);
      }
    }

    // Clean up all relay connections immediately
    for (final relay in _relays.values) {
      // Cancel all stream subscriptions first
      relay.connectionSubscription?.cancel();
      relay.messageSubscription?.cancel();

      // Cancel all timers
      relay.reconnectTimer?.cancel();
      relay.idleTimer?.cancel();

      // Close and nullify socket immediately
      if (relay.socket != null) {
        try {
          relay.socket!.close();
        } catch (e) {
          // Ignore close errors during disposal
        }
        relay.socket = null; // Nullify reference immediately
      }
    }

    // Clear all state immediately
    _relays.clear();
    _subscriptions.clear();
    _seenEventRelays.clear();

    // Give a brief moment for final cleanup
    await Future.delayed(Duration(milliseconds: 50));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    // Cancel all subscriptions and timers first
    for (final subscription in _subscriptions.values) {
      subscription.streamingBuffer?.cancel();
      subscription.eoseTimeoutTimer?.cancel();
      // Complete any pending query completers to prevent hanging
      if (subscription.queryCompleter != null &&
          !subscription.queryCompleter!.isCompleted) {
        subscription.queryCompleter!.complete([]);
      }
    }

    // Synchronous cleanup for compatibility
    for (final relay in _relays.values) {
      relay.connectionSubscription?.cancel();
      relay.messageSubscription?.cancel();
      relay.reconnectTimer?.cancel();
      relay.idleTimer?.cancel();
      try {
        relay.socket?.close();
      } catch (e) {
        // Ignore close errors during disposal
      }
      relay.socket = null; // Nullify reference immediately
    }

    // Clear all state
    _relays.clear();
    _subscriptions.clear();
    _seenEventRelays.clear();

    // Call parent dispose
    super.dispose();
  }

  /// Normalizes relay URLs by removing trailing slashes and ensuring consistent format
  Set<String> _normalizeUrls(Set<String> urls) {
    return urls.map((url) {
      final normalized =
          url.endsWith('/') && url.length > 1
              ? url.substring(0, url.length - 1)
              : url;
      return normalized;
    }).toSet();
  }

  Future<void> send(
    RequestFilter req, {
    Set<String> relayUrls = const {},
  }) async {
    if (relayUrls.isEmpty) return;

    // Normalize URLs - remove trailing slashes and ensure consistent format
    final normalizedUrls = _normalizeUrls(relayUrls);

    // Create subscription state
    final subscription = SubscriptionState(
      filter: req,
      targetRelays: normalizedUrls,
    );
    _subscriptions[req.subscriptionId] = subscription;

    // Start timeout timer for ENTIRE process (6 seconds from now)
    subscription.eoseTimeoutTimer = Timer(Duration(seconds: 6), () async {
      final sub = _subscriptions[req.subscriptionId];
      if (sub != null && sub.phase == SubscriptionPhase.initial) {
        // Timeout reached, emit whatever we have
        sub.phase = SubscriptionPhase.streaming;

        // Complete query completer if this is a query() call
        if (sub.queryCompleter != null && !sub.queryCompleter!.isCompleted) {
          sub.queryCompleter!.complete(List.from(sub.bufferedEvents));
        } else {
          // Regular subscription - emit buffered events
          await _emitBufferedEvents(req.subscriptionId);
        }
      }
    });

    // Connect to relays asynchronously and send requests as they connect
    final message = jsonEncode(['REQ', req.subscriptionId, req.toMap()]);

    // Don't await - let connections happen in parallel
    for (final url in normalizedUrls) {
      _ensureConnection(url)
          .then((_) {
            // Send request as soon as this relay connects
            final relay = _relays[url];
            if (relay?.isConnected == true) {
              relay!.socket!.send(message);
              relay.lastActivity = DateTime.now();
              _resetIdleTimer(url);
              subscription.connectedRelays.add(
                url,
              ); // Track which relays we sent to
            }
          })
          .catchError((error) {
            // Connection failed for this relay, continue with others
            // The timeout will handle this case
          });
    }
  }

  Future<void> publish(
    List<Map<String, dynamic>> events, {
    Set<String> relayUrls = const {},
  }) async {
    if (relayUrls.isEmpty || events.isEmpty) return;

    // Normalize URLs - remove trailing slashes and ensure consistent format
    final normalizedUrls = _normalizeUrls(relayUrls);

    // Ensure connections to all relays
    for (final url in normalizedUrls) {
      await _ensureConnection(url);
    }

    // Send EVENT messages to all connected relays
    for (final event in events) {
      final message = jsonEncode(['EVENT', event]);
      for (final url in normalizedUrls) {
        final relay = _relays[url];
        if (relay?.isConnected == true) {
          relay!.socket!.send(message);
          relay.lastActivity = DateTime.now();
          _resetIdleTimer(url);
        }
      }
    }
  }

  void unsubscribe(RequestFilter req) {
    final subscriptionId = req.subscriptionId;
    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    // Send CLOSE message to all target relays
    final message = jsonEncode(['CLOSE', subscriptionId]);
    for (final url in subscription.targetRelays) {
      final relay = _relays[url];
      if (relay?.isConnected == true) {
        relay!.socket!.send(message);
        relay.lastActivity = DateTime.now();
        _resetIdleTimer(url);
      }
    }

    // Clean up subscription
    subscription.streamingBuffer?.cancel();
    subscription.eoseTimeoutTimer?.cancel();
    _subscriptions.remove(subscriptionId);

    // Check if any relay has no more active subscriptions and close if idle
    _cleanupIdleRelays(subscription.targetRelays);
  }

  /// Close relay connections that have no active subscriptions
  void _cleanupIdleRelays(Set<String> relayUrls) {
    for (final url in relayUrls) {
      final hasActiveSubscriptions = _subscriptions.values.any(
        (sub) => sub.targetRelays.contains(url),
      );

      if (!hasActiveSubscriptions) {
        final relay = _relays[url];
        if (relay != null) {
          // Cancel all timers to prevent reconnection
          relay.reconnectTimer?.cancel();
          relay.idleTimer?.cancel();

          // Close the socket cleanly - this will trigger disconnection
          if (relay.socket != null) {
            try {
              relay.socket!.close();
            } catch (e) {
              // Ignore close errors
            }
          }
        }
      }
    }
  }

  // TODO: Should return RelayResponse with metadata
  Future<List<Map<String, dynamic>>> query(
    RequestFilter req, {
    Set<String> relayUrls = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // Send the request first
    await send(req, relayUrls: relayUrls);

    final subscription = _subscriptions[req.subscriptionId];
    if (subscription == null) {
      return [];
    }

    final completer = Completer<List<Map<String, dynamic>>>();
    subscription.queryCompleter = completer;

    Timer? timeoutTimer;
    if (timeout > Duration.zero) {
      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.complete(List.from(subscription.bufferedEvents));
        }
      });
    }

    try {
      final events = await completer.future;
      return events;
    } finally {
      timeoutTimer?.cancel();
      unsubscribe(req);
    }
  }

  Future<void> _ensureConnection(String url) async {
    final relay = _relays.putIfAbsent(url, () => RelayState());

    if (relay.isConnected || relay.isConnecting || relay.isDead) {
      return;
    }

    await _connect(url);
  }

  Future<void> _connect(String url) async {
    if (_disposed) return; // Don't connect if disposed

    final relay = _relays[url]!;

    if (relay.isDead) return;

    // If we already have a connected socket, don't create another one
    if (relay.isConnected) return;

    try {
      final socket = WebSocket(
        Uri.parse(url),
        backoff: BinaryExponentialBackoff(
          initial: Duration(milliseconds: 100),
          maximumStep: 8,
        ),
      );

      relay.socket = socket;
      relay.lastActivity = DateTime.now();
      relay.reconnectAttempts = 0;
      relay.firstFailureTime = null;

      _resetIdleTimer(url);
      _setupSocketListeners(url, socket);

      // Wait for connection to be established, but with timeout to prevent hanging
      final connectionFuture = socket.connection.firstWhere(
        (state) => state is Connected,
        orElse: () => throw TimeoutException('Connection timeout'),
      );

      await connectionFuture.timeout(Duration(seconds: 30));

      // Verify we're still not disposed before proceeding
      if (_disposed) {
        socket.close();
        return;
      }

      // Give the server a moment to set up its message handler
      await Future.delayed(Duration(milliseconds: 50));

      // Re-send active subscriptions to this relay
      await _resendSubscriptions(url);
    } catch (e) {
      // Only handle failure if not disposed
      if (!_disposed) {
        await _handleConnectionFailure(url);
      }
    }
  }

  void _setupSocketListeners(String url, WebSocket socket) {
    final relay = _relays[url]!;

    // Listen to connection state changes
    relay.connectionSubscription = socket.connection.listen((state) {
      if (state is Disconnected) {
        _handleDisconnection(url);
      }
    }, onError: (error) => _handleConnectionFailure(url));

    // Listen to messages
    relay.messageSubscription = socket.messages.listen(
      (message) async => await _handleMessage(url, message),
      onError: (error) => _handleConnectionFailure(url),
    );
  }

  Future<void> _handleMessage(String url, dynamic message) async {
    final relay = _relays[url]!;
    relay.lastActivity = DateTime.now();
    _resetIdleTimer(url);

    try {
      final List<dynamic> data = jsonDecode(message);
      final messageType = data[0] as String;

      switch (messageType) {
        case 'EVENT':
          _handleEvent(url, data);
          break;
        case 'EOSE':
          await _handleEose(url, data);
          break;
        case 'OK':
          _handleOk(url, data);
          break;
        case 'NOTICE':
          _handleNotice(url, data);
          break;
      }
    } catch (e) {
      // Invalid message format, ignore
    }
  }

  void _handleEvent(String url, List<dynamic> data) {
    if (data.length < 3) return;

    final subscriptionId = data[1] as String;
    final event = data[2] as Map<String, dynamic>;
    final eventId = event['id'] as String?;

    if (eventId == null) return;

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    // Always track which relay sent this event
    _seenEventRelays.putIfAbsent(eventId, () => <String>{}).add(url);

    // Check if this event is already buffered for this subscription
    final alreadyBuffered = subscription.bufferedEvents.any(
      (bufferedEvent) => bufferedEvent['id'] == eventId,
    );

    if (alreadyBuffered) {
      return; // Event already in buffer for this subscription
    }

    if (subscription.phase == SubscriptionPhase.initial) {
      // Buffer event until EOSE
      subscription.bufferedEvents.add(event);
    } else {
      // Streaming phase - buffer with timeout
      subscription.bufferedEvents.add(event);
      subscription.lastEventTime = DateTime.now();
      _scheduleStreamingFlush(subscriptionId);
    }
  }

  Future<void> _handleEose(String url, List<dynamic> data) async {
    if (data.length < 2) return;

    final subscriptionId = data[1] as String;
    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    subscription.eoseReceived.add(url);

    if (subscription.allEoseReceived &&
        subscription.phase == SubscriptionPhase.initial) {
      // All target relays sent EOSE, cancel timeout timer
      subscription.eoseTimeoutTimer?.cancel();
      subscription.phase = SubscriptionPhase.streaming;

      // Complete query completer if this is a query() call
      if (subscription.queryCompleter != null &&
          !subscription.queryCompleter!.isCompleted) {
        subscription.queryCompleter!.complete(
          List.from(subscription.bufferedEvents),
        );
      } else {
        // Regular subscription - emit buffered events
        await _emitBufferedEvents(subscriptionId);
      }
    }
  }

  void _handleOk(String url, List<dynamic> data) {
    if (data.length < 4) return;

    final eventId = data[1] as String;
    final accepted = data[2] as bool;
    final message = data[3] as String;

    final response = PublishRelayResponse(
      id: eventId,
      relayUrl: url,
      accepted: accepted,
      message: message,
    );

    _addResponse(response);
  }

  void _handleNotice(String url, List<dynamic> data) {
    if (data.length < 2) return;

    final message = data[1] as String;

    final response = NoticeRelayResponse(message: message, relayUrl: url);

    _addResponse(response);
  }

  Future<void> _emitBufferedEvents(String subscriptionId) async {
    if (_disposed) return;

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null || subscription.bufferedEvents.isEmpty) return;

    final responses = <RelayResponse>[];
    final eventsToProcess = List.from(subscription.bufferedEvents);

    for (final event in eventsToProcess) {
      if (await isEventValid(event)) {
        final eventId = event['id'] as String?;
        final relayUrls =
            eventId != null
                ? (_seenEventRelays[eventId] ?? <String>{})
                : <String>{};

        final response = EventRelayResponse(
          event: event,
          req: subscription.filter,
          relayUrls: relayUrls, // Use actual relays that sent this event
        );
        responses.add(response);
      }
    }

    if (responses.isNotEmpty && !_disposed) {
      final currentState = state ?? <RelayResponse>[];
      state = [...currentState, ...responses];
    }

    subscription.bufferedEvents.clear();
  }

  void _scheduleStreamingFlush(String subscriptionId) {
    if (_disposed) return;

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    subscription.streamingBuffer?.cancel();
    subscription.streamingBuffer = Timer(_streamingBufferTimeout, () async {
      if (!_disposed) {
        await _emitBufferedEvents(subscriptionId);
      }
    });
  }

  void _addResponse(RelayResponse response) {
    if (_disposed) return;

    final currentState = state ?? <RelayResponse>[];
    state = [...currentState, response];
  }

  Future<void> _handleConnectionFailure(String url) async {
    if (_disposed) return; // Don't attempt reconnection if disposed

    final relay = _relays[url]!;

    // Close the socket if it exists
    if (relay.socket != null) {
      try {
        relay.socket?.close();
      } catch (e) {
        // Ignore close errors during failure handling
      }
    }

    relay.socket = null;
    relay.reconnectAttempts++;

    // Mark as dead if trying for 4 hours
    final now = DateTime.now();
    relay.firstFailureTime ??= now;

    if (now.difference(relay.firstFailureTime!).inHours >= 4) {
      relay.isDead = true;
      return;
    }

    // Schedule reconnection only if not disposed and not dead
    if (!_disposed && !relay.isDead) {
      final delay = Duration(
        milliseconds: min(
          100 * pow(2, relay.reconnectAttempts).toInt(),
          30000, // Max 30 seconds
        ),
      );

      relay.reconnectTimer = Timer(delay, () {
        if (!_disposed && !relay.isDead) {
          _connect(url);
        }
      });
    }
  }

  void _handleDisconnection(String url) {
    if (_disposed) return; // Don't handle disconnections if disposed

    final relay = _relays[url];
    if (relay == null) return;

    // Only clean up timers and subscriptions, let the socket state speak for itself
    relay.idleTimer?.cancel();
    relay.connectionSubscription?.cancel();
    relay.messageSubscription?.cancel();

    // Only attempt reconnection if the socket indicates we should
    if (!_disposed && relay.shouldReconnect) {
      _handleConnectionFailure(url);
    }
  }

  void _resetIdleTimer(String url) {
    final relay = _relays[url];
    if (relay == null) return;

    relay.idleTimer?.cancel();
    relay.idleTimer = Timer(_idleTimeout, () {
      if (relay.socket != null) {
        relay.socket?.close();
      }
    });
  }

  Future<void> _resendSubscriptions(String url) async {
    for (final subscription in _subscriptions.values) {
      if (subscription.targetRelays.contains(url)) {
        final filter = subscription.filter;

        // Adjust filter based on subscription phase
        if (subscription.phase == SubscriptionPhase.streaming) {
          // Re-issue with current timestamp as 'since'
          final adjustedFilter = filter.copyWith(since: DateTime.now());
          final message = jsonEncode([
            'REQ',
            filter.subscriptionId,
            adjustedFilter.toMap(),
          ]);
          _relays[url]?.socket?.send(message);
        } else {
          // Re-send original filter
          final message = jsonEncode([
            'REQ',
            filter.subscriptionId,
            filter.toMap(),
          ]);
          _relays[url]?.socket?.send(message);
        }
      }
    }
  }

  Future<bool> isEventValid(Map<String, dynamic> event) async {
    // Dummy implementation - always returns true
    // This will be completed later
    return true;
  }

  // Getters for testing
  Map<String, Set<String>> get seenEventRelays => _seenEventRelays;
  Map<String, RelayState> get relays => _relays;
  Map<String, SubscriptionState> get subscriptions => _subscriptions;
}

sealed class RelayResponse {}

// For 'EVENT'/'EOSE' responses
class EventRelayResponse extends RelayResponse {
  final Map<String, dynamic> event;
  final RequestFilter req; // which request filter the event is related to
  final Set<String> relayUrls; // which relays returned it

  EventRelayResponse({
    required this.event,
    required this.req,
    required this.relayUrls,
  });
}

// Specific for 'OK' response
class PublishRelayResponse extends RelayResponse {
  final String id; // event ID
  final String relayUrl;
  final bool accepted;
  final String message;

  PublishRelayResponse({
    required this.id,
    required this.relayUrl,
    required this.accepted,
    required this.message,
  });
}

// For 'NOTICE' response
class NoticeRelayResponse extends RelayResponse {
  final String message;
  final String relayUrl;

  NoticeRelayResponse({required this.message, required this.relayUrl});
}
