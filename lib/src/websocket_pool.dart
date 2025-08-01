import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:models/models.dart';
import 'package:purplebase/src/relay_status_types.dart';
import 'package:riverpod/riverpod.dart';
import 'package:web_socket_client/web_socket_client.dart';

class WebSocketPool extends StateNotifier<RelayResponse?> {
  final Map<String, RelayState> _relays = {};
  final Map<String, SubscriptionState> _subscriptions = {};
  final Map<String, PublishState> _publishStates = {};
  final StorageConfiguration config;

  // Info listeners
  final List<void Function(String)> _infoListeners = [];

  // Relay status listeners
  final List<void Function(RelayStatusData)> _relayStatusListeners = [];

  // LRU cache for relay-request timestamp optimization (max 1000 entries)
  final Map<String, DateTime> _relayRequestTimestamps = {};
  final List<String> _timestampKeys = []; // For LRU ordering
  static const int _maxTimestampEntries = 1000;

  WebSocketPool(this.config) : super(null);

  /// Add a info listener that receives messages
  void Function() addInfoListener(void Function(String) listener) {
    _infoListeners.add(listener);
    return () => _infoListeners.remove(listener);
  }

  /// Send info message to all listeners
  void _info(String message) {
    for (final listener in _infoListeners) {
      listener(message);
    }
  }

  /// Add a relay status listener that receives status updates
  void Function() addRelayStatusListener(
    void Function(RelayStatusData) listener,
  ) {
    _relayStatusListeners.add(listener);
    return () => _relayStatusListeners.remove(listener);
  }

  /// Send relay status update to all listeners
  void _emitRelayStatus() {
    if (_relayStatusListeners.isEmpty) return;

    final statusData = _buildRelayStatusData();
    for (final listener in _relayStatusListeners) {
      listener(statusData);
    }
  }

  /// Build current relay status data
  RelayStatusData _buildRelayStatusData() {
    // Build relay connection info
    final relayInfo = <String, RelayConnectionInfo>{};
    for (final entry in _relays.entries) {
      final url = entry.key;
      final relay = entry.value;

      RelayConnectionState state;
      if (relay.isConnected) {
        state = RelayConnectionState.connected;
      } else if (relay.isConnecting) {
        state = RelayConnectionState.connecting;
      } else {
        state = RelayConnectionState.disconnected;
      }

      relayInfo[url] = RelayConnectionInfo(
        url: url,
        state: state,
        lastActivity: relay.lastActivity,
        reconnectAttempts: relay.reconnectAttempts,
      );
    }

    // Build active request info
    final requestInfo = <String, ActiveRequestInfo>{};
    for (final entry in _subscriptions.entries) {
      final subscriptionId = entry.key;
      final subscription = entry.value;

      requestInfo[subscriptionId] = ActiveRequestInfo(
        subscriptionId: subscriptionId,
        targetRelays: subscription.targetRelays,
        connectedRelays: subscription.connectedRelays,
        eoseReceived: subscription.eoseReceived,
        phase: subscription.phase,
        startTime: DateTime.now(), // TODO: Track actual start time
      );
    }

    // Build publish request info (simplified for now)
    final publishInfo = <String, PublishRequestInfo>{};
    for (final entry in _publishStates.entries) {
      final id = entry.key;
      final publishState = entry.value;

      publishInfo[id] = PublishRequestInfo(
        id: id,
        targetRelays: publishState.targetRelays.toList(), // Convert Set to List
        relayResults: {}, // TODO: Build from pendingResponses and failedRelays
        startTime: DateTime.now(), // TODO: Track actual start time
      );
    }

    return RelayStatusData(
      relays: relayInfo,
      activeRequests: requestInfo,
      publishRequests: publishInfo,
    );
  }

  /// Create a canonical version of the request for hashing (without since/until)
  Request _canonicalRequest(Request req) {
    final canonicalFilters = req.filters.map((filter) {
      // Only remove since for optimization, keep until as it's a query constraint
      return filter.copyWith(since: DateTime.fromMillisecondsSinceEpoch(0));
    }).toList();
    return Request(canonicalFilters);
  }

  /// Hash a relay-request pair for timestamp tracking
  String _hashRelayRequestPair(String relayUrl, Request req) {
    // Use canonical request (without since) for consistent hashing
    final canonicalReq = _canonicalRequest(req);
    final data = utf8.encode(relayUrl + canonicalReq.toString());
    final digest = sha256.convert(data);
    return digest.toString();
  }

  /// Get timestamp for relay-request pair, return 0 if not found
  @protected
  @visibleForTesting
  DateTime? getRelayRequestTimestamp(String relayUrl, Request req) {
    final hash = _hashRelayRequestPair(relayUrl, req);
    return _relayRequestTimestamps[hash];
  }

  /// Store timestamp for relay-request pair with LRU eviction
  void _storeRelayRequestTimestamp(
    String relayUrl,
    Request req,
    DateTime timestamp,
  ) {
    final hash = _hashRelayRequestPair(relayUrl, req);

    // Remove from LRU list if it exists
    _timestampKeys.remove(hash);

    // Add to front of LRU list
    _timestampKeys.insert(0, hash);

    // Store the timestamp
    _relayRequestTimestamps[hash] = timestamp;

    // Evict oldest if we exceed max entries
    if (_timestampKeys.length > _maxTimestampEntries) {
      final oldestKey = _timestampKeys.removeLast();
      _relayRequestTimestamps.remove(oldestKey);
    }
  }

  /// Optimize request filters for a specific relay based on stored timestamps
  @protected
  @visibleForTesting
  Request optimizeRequestForRelay(String relayUrl, Request originalReq) {
    // Hash the original request BEFORE any modifications
    final storedTimestamp = getRelayRequestTimestamp(relayUrl, originalReq);

    if (storedTimestamp == null) {
      // No stored timestamp, return original request
      return originalReq;
    }

    // Create optimized filters
    final optimizedFilters = originalReq.filters.map((filter) {
      // If filter has a newer since value, keep it; otherwise use stored timestamp
      if (filter.since != null && filter.since!.isAfter(storedTimestamp)) {
        return filter;
      }
      return filter.copyWith(since: storedTimestamp);
    }).toList();

    return Request(optimizedFilters);
  }

  Future<void> send(
    Request req, {
    Set<String> relayUrls = const {},
    Completer<List<Map<String, dynamic>>>? queryCompleter,
  }) async {
    if (relayUrls.isEmpty) return;

    _info(
      'Sending request $req to ${relayUrls.length} relay(s): [${relayUrls.join(', ')}]',
    );

    // Create subscription state
    final subscription = SubscriptionState(req: req, targetRelays: relayUrls);
    _subscriptions[req.subscriptionId] = subscription;

    // Emit relay status update
    _emitRelayStatus();

    // Set up query completer if provided (to avoid race condition with timeout)
    if (queryCompleter != null) {
      subscription.queryCompleter = queryCompleter;
    }

    // Start timeout timer for ENTIRE process (responseTimeout from config)
    subscription.eoseTimer = Timer(
      config.responseTimeout,
      () => _flushEventBuffer(req.subscriptionId),
    );

    // Connect to relays asynchronously and send optimized requests as they connect
    final futureFns = <Future>[];
    for (final url in relayUrls) {
      final future = _ensureConnection(url)
          .then((_) {
            // Send optimized request as soon as this relay connects
            final relay = _relays[url];
            if (relay?.isConnected == true) {
              // Optimize request for this specific relay
              final optimizedReq = optimizeRequestForRelay(url, req);
              final message = jsonEncode([
                'REQ',
                req.subscriptionId,
                ...optimizedReq.toMaps(),
              ]);

              try {
                relay!.socket!.send(message);
                relay.lastActivity = DateTime.now();
                _resetIdleTimer(url);
                subscription.connectedRelays.add(
                  url,
                ); // Track which relays we sent to
              } catch (e) {
                _info(
                  'ERROR: Failed to send request ${req.subscriptionId} to relay $url - $e',
                );
                // Continue with other relays
              }
            }
          })
          .catchError((error) {
            print(error);
            _info(
              'ERROR: Failed to send request ${req.subscriptionId} to relay $url - $error',
            );
            // Connection failed for this relay, continue with others
            // The timeout will handle this case
          });
      futureFns.add(future);
    }
    await Future.wait(futureFns);
  }

  Future<List<Map<String, dynamic>>> query(
    Request req, {
    RemoteSource source = const RemoteSource(),
  }) async {
    final relayUrls = config.getRelays(source: source);

    // Set up completer first to avoid race condition with timeout
    final completer = Completer<List<Map<String, dynamic>>>();

    // Send the request first, passing the completer to avoid race condition
    await send(req, relayUrls: relayUrls, queryCompleter: completer);

    final subscription = _subscriptions[req.subscriptionId];
    if (subscription == null) {
      return [];
    }

    // Return nothing if we only care about new models showing up via the notifier
    if (source.background) {
      return [];
    }

    List<Map<String, dynamic>> events;
    try {
      events = await completer.future;
    } finally {
      if (source.stream == false) {
        unsubscribe(req);
      }
    }
    return events;
  }

  Future<PublishRelayResponse> publish(
    List<Map<String, dynamic>> events, {
    RemoteSource source = const RemoteSource(),
  }) async {
    final relayUrls = config.getRelays(source: source);

    if (relayUrls.isEmpty || events.isEmpty) {
      return PublishRelayResponse();
    }

    _info(
      'Publishing ${events.length} event(s) to ${relayUrls.length} relay(s): [${relayUrls.join(', ')}]',
    );

    // Create publish state to track responses
    final publishId = DateTime.now().millisecondsSinceEpoch.toString();
    final publishState = PublishState(
      events: events,
      targetRelays: relayUrls,
      publishId: publishId,
    );
    _publishStates[publishId] = publishState;

    // Set up timeout (responseTimeout from config)
    publishState.timeoutTimer = Timer(
      config.responseTimeout,
      () => _flushPublishBuffer(publishId),
    );

    // Prepare EVENT messages
    final eventMessages = <String, String>{}; // eventId -> message
    for (final event in events) {
      final eventId = event['id'] as String?;
      if (eventId != null) {
        publishState.pendingEventIds.add(eventId);
        eventMessages[eventId] = jsonEncode(['EVENT', event]);
      }
    }

    // Connect to relays asynchronously and send events as they connect
    for (final url in relayUrls) {
      _ensureConnection(url)
          .then((_) {
            // Send events as soon as this relay connects
            final relay = _relays[url];
            if (relay?.isConnected == true) {
              for (final entry in eventMessages.entries) {
                final eventId = entry.key;
                final message = entry.value;

                try {
                  relay!.socket!.send(message);
                  relay.lastActivity = DateTime.now();
                  _resetIdleTimer(url);

                  // Track that we sent this event to this relay
                } catch (e) {
                  _info(
                    'ERROR: Failed to send event $eventId to relay $url - $e',
                  );
                  // Mark this relay as failed for this event
                  publishState.failedRelays
                      .putIfAbsent(eventId, () => <String>{})
                      .add(url);
                  continue; // Skip to next event
                }
                publishState.sentToRelays
                    .putIfAbsent(eventId, () => <String>{})
                    .add(url);
              }
            }
          })
          .catchError((error) {
            // Connection failed for this relay, continue with others
            // Mark this relay as unreachable for all events
            for (final eventId in publishState.pendingEventIds) {
              publishState.failedRelays
                  .putIfAbsent(eventId, () => <String>{})
                  .add(url);
            }
          });
    }

    // Wait for responses or timeout
    final completer = Completer<PublishRelayResponse>();
    publishState.completer = completer;

    try {
      return await completer.future;
    } finally {
      publishState.timeoutTimer?.cancel();
      _publishStates.remove(publishId);
    }
  }

  void unsubscribe(Request req) {
    final subscriptionId = req.subscriptionId;
    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    _info(
      'Unsubscribing from ${subscription.targetRelays.length} relay(s) for subscription: $subscriptionId',
    );

    // Send CLOSE message to all target relays
    final message = jsonEncode(['CLOSE', subscriptionId]);
    for (final url in subscription.targetRelays) {
      final relay = _relays[url];
      if (relay?.isConnected == true) {
        try {
          relay!.socket!.send(message);
          relay.lastActivity = DateTime.now();
          _resetIdleTimer(url);
        } catch (e) {
          _info('ERROR: Failed to send CLOSE to relay $url - $e');
          // Continue with other relays
        }
      }
    }

    // Clean up subscription
    subscription.streamingBuffer?.cancel();
    subscription.eoseTimer?.cancel();
    _subscriptions.remove(subscriptionId);

    // Emit relay status update
    _emitRelayStatus();

    // Check if any relay has no more active subscriptions and close if idle
    _cleanupIdleRelays(subscription.targetRelays);
  }

  @override
  void dispose() {
    if (!mounted) return;

    // Cancel all subscriptions and timers first
    for (final subscription in _subscriptions.values) {
      subscription.streamingBuffer?.cancel();
      subscription.eoseTimer?.cancel();
      // Complete any pending query completers to prevent hanging
      if (subscription.queryCompleter != null &&
          !subscription.queryCompleter!.isCompleted) {
        subscription.queryCompleter!.complete([]);
      }
    }

    // Cancel all publish states and timers
    for (final publishState in _publishStates.values) {
      publishState.timeoutTimer?.cancel();
      if (publishState.completer != null &&
          !publishState.completer!.isCompleted) {
        publishState.completer!.complete(PublishRelayResponse());
      }
    }

    for (final relay in _relays.values) {
      // Mark as intentional disconnection during disposal
      relay.intentionalDisconnection = true;
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
    _publishStates.clear();

    // Call parent dispose
    super.dispose();
  }

  // Keep private methods below this comment

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

          // Mark as intentional disconnection since we're cleaning up
          relay.intentionalDisconnection = true;

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

  Future<void> _ensureConnection(String url) async {
    final relay = _relays.putIfAbsent(url, () => RelayState());

    if (relay.isConnected || relay.isConnecting) {
      return;
    }

    await _connect(url);
  }

  Future<void> _connect(String url) async {
    if (!mounted) return; // Don't connect if disposed

    final relay = _relays[url]!;

    // If we already have a connected socket, don't create another one
    if (relay.isConnected) return;

    _info('Connecting to relay: $url');

    try {
      // Validate URL format before attempting connection
      final uri = Uri.parse(url);
      if (uri.scheme != 'ws' && uri.scheme != 'wss') {
        throw FormatException('Invalid WebSocket scheme: ${uri.scheme}');
      }
      if (uri.host.isEmpty) {
        throw FormatException('Empty host in URL: $url');
      }

      // Create WebSocket with timeout to prevent hanging on invalid URLs
      final socket = await Future(
        () => WebSocket(
          uri,
          backoff: BinaryExponentialBackoff(
            initial: Duration(milliseconds: 100),
            maximumStep: 8,
          ),
        ),
      ).timeout(config.responseTimeout);

      relay.socket = socket;
      relay.lastActivity = DateTime.now();
      relay.reconnectAttempts = 0;

      _resetIdleTimer(url);
      _setupSocketListeners(url, socket);

      // Wait for connection to be established, but with timeout to prevent hanging
      final connectionFuture = socket.connection.firstWhere(
        (state) => state is Connected,
        orElse: () => throw TimeoutException('Connection timeout'),
      );

      await connectionFuture.timeout(config.responseTimeout);

      // Verify we're still not disposed before proceeding
      if (!mounted) {
        socket.close();
        return;
      }

      _info('Successfully connected to relay: $url');

      // Emit relay status update
      _emitRelayStatus();

      // Re-send active subscriptions to this relay
      await _resendSubscriptions(url);
    } catch (e) {
      _info('ERROR: Failed to connect to relay $url - $e');
      // Connection failed - rethrow so that the publish method can handle it
      rethrow;
    }
  }

  void _setupSocketListeners(String url, WebSocket socket) {
    final relay = _relays[url]!;

    // Listen to connection state changes
    relay.connectionSubscription = socket.connection.listen((state) {
      if (state is Disconnected) {
        _handleDisconnection(url);
      } else if (state is Reconnected) {
        _handleReconnection(url);
      } else if (state is Reconnecting) {
        _handleReconnecting(url);
      }
    });

    // Listen to messages
    relay.messageSubscription = socket.messages.listen(
      (message) async => await _handleMessage(url, message),
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
          handleEvent(url, data);
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

  @protected
  @visibleForTesting
  void handleEvent(String url, List<dynamic> data) {
    if (data.length < 3) return;

    final subscriptionId = data[1] as String;
    final event = data[2] as Map<String, dynamic>;
    final eventId = event['id'] as String?;

    if (eventId == null) return;

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    // Always track which relay sent this event
    subscription.relaysForId.putIfAbsent(eventId, () => <String>{}).add(url);

    // Check if this event is already buffered for this subscription
    final alreadyBuffered = subscription.bufferedEvents.any(
      (bufferedEvent) => bufferedEvent['id'] == eventId,
    );

    if (alreadyBuffered) {
      return; // Event already in buffer for this subscription
    }

    // Track latest timestamp for this relay-request pair
    final eventTimestamp = event['created_at'] as int?;
    if (eventTimestamp != null) {
      _storeRelayRequestTimestamp(
        url,
        subscription.req,
        DateTime.fromMillisecondsSinceEpoch(eventTimestamp * 1000),
      );
    }

    // Remove signature if keepSignatures is false
    final processedEvent = Map<String, dynamic>.from(event);

    if (subscription.phase == SubscriptionPhase.eose) {
      // Buffer event until EOSE
      subscription.bufferedEvents.add(processedEvent);
    } else {
      // Streaming phase - buffer with timeout
      subscription.bufferedEvents.add(processedEvent);
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
        subscription.phase == SubscriptionPhase.eose) {
      // All target relays sent EOSE, cancel timeout timer
      subscription.eoseTimer?.cancel();
      _flushEventBuffer(subscriptionId);
    }
  }

  void _handleOk(String url, List<dynamic> data) {
    if (data.length < 4) return;

    final eventId = data[1] as String;
    final accepted = data[2] as bool;
    final message = data.length > 3 ? data[3] as String? : null;

    // Find publish states that are waiting for this event
    for (final publishState in [..._publishStates.values]) {
      if (publishState.pendingEventIds.contains(eventId)) {
        // Check if this relay was supposed to receive this event
        final relaysForEvent = publishState.sentToRelays[eventId];
        if (relaysForEvent != null && relaysForEvent.contains(url)) {
          publishState.response.wrapped.addEvent(
            eventId,
            relayUrl: url,
            accepted: accepted,
            message: message,
          );

          // Remove this relay from pending for this event
          publishState.pendingResponses
              .putIfAbsent(eventId, () => <String>{})
              .add(url);

          // Check if we have all responses for all events
          if (publishState.allResponsesReceived) {
            publishState.timeoutTimer?.cancel();
            _flushPublishBuffer(publishState.publishId);
          }
        }
      }
    }
  }

  void _handleNotice(String url, List<dynamic> data) {
    if (!mounted || data.length < 2) return;
    final message = data[1] as String;
    state = NoticeRelayResponse(message: message, relayUrl: url);
  }

  // Used to emit EOSE and streaming-buffered events
  Future<void> _flushEventBuffer(String subscriptionId) async {
    if (!mounted) return;

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    // Clear the timer so new flushes can be scheduled (for throttling)
    subscription.streamingBuffer = null;

    if (subscription.phase == SubscriptionPhase.eose) {
      subscription.phase = SubscriptionPhase.streaming;

      // Complete query completer if this is a query() call - even with empty results
      // Handle race condition where completer might not be set up yet
      if (subscription.queryCompleter != null &&
          !subscription.queryCompleter!.isCompleted) {
        subscription.queryCompleter!.complete(
          List.from(subscription.bufferedEvents),
        );
      }
    }

    // Only emit state if there are buffered events
    if (subscription.bufferedEvents.isNotEmpty) {
      // Create copies to avoid clearing the Set while it's being used
      final eventsCopy = Set<Map<String, dynamic>>.from(
        subscription.bufferedEvents,
      );
      final relaysCopy = Map<String, Set<String>>.from(
        subscription.relaysForId,
      );

      state = EventRelayResponse(
        req: subscription.req,
        events: eventsCopy,
        relaysForIds: relaysCopy,
      );

      subscription.bufferedEvents.clear();
      subscription.relaysForId.clear();
    }
  }

  Future<void> _flushPublishBuffer(String publishId) async {
    if (!mounted) return;

    final publishState = _publishStates[publishId];
    if (publishState == null) return;

    // Complete the publish operation
    if (publishState.completer != null &&
        !publishState.completer!.isCompleted) {
      // If we have events, track per-event unreachable relays
      if (publishState.pendingEventIds.isNotEmpty) {
        // Mark unreachable relays for events that didn't get responses
        for (final eventId in publishState.pendingEventIds) {
          final sentTo = publishState.sentToRelays[eventId] ?? <String>{};
          final respondedFrom =
              publishState.pendingResponses[eventId] ?? <String>{};
          final failedConnections =
              publishState.failedRelays[eventId] ?? <String>{};
          final unreachable = sentTo.difference(respondedFrom);

          // Add relays that failed to connect and relays that didn't respond
          publishState.response.wrapped.unreachableRelayUrls.addAll(
            unreachable,
          );
          publishState.response.wrapped.unreachableRelayUrls.addAll(
            failedConnections,
          );

          // Also add relays we targeted but never successfully sent to
          final neverSentTo = publishState.targetRelays
              .difference(sentTo)
              .difference(failedConnections);
          publishState.response.wrapped.unreachableRelayUrls.addAll(
            neverSentTo,
          );
        }
      } else {
        // No events to track, just mark all target relays as unreachable if we never sent anything
        final allSentToRelays = publishState.sentToRelays.values
            .expand((urls) => urls)
            .toSet();
        final allFailedRelays = publishState.failedRelays.values
            .expand((urls) => urls)
            .toSet();
        final neverConnected = publishState.targetRelays
            .difference(allSentToRelays)
            .difference(allFailedRelays);
        publishState.response.wrapped.unreachableRelayUrls.addAll(
          neverConnected,
        );
        publishState.response.wrapped.unreachableRelayUrls.addAll(
          allFailedRelays,
        );
      }

      final totalEvents = publishState.pendingEventIds.length;
      final unreachableCount =
          publishState.response.wrapped.unreachableRelayUrls.length;
      _info(
        'Flushing publish buffer for $totalEvents event(s), $unreachableCount unreachable relay(s)',
      );

      publishState.completer!.complete(publishState.response);
    }

    publishState.timeoutTimer?.cancel();
    _publishStates.remove(publishId);
  }

  void _scheduleStreamingFlush(String subscriptionId) {
    if (!mounted) return;

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    // Throttling: only schedule if not already scheduled
    if (subscription.streamingBuffer?.isActive != true) {
      subscription.streamingBuffer = Timer(
        config.streamingBufferWindow,
        () => _flushEventBuffer(subscriptionId),
      );
    }
  }

  void _handleDisconnection(String url) {
    if (!mounted) return; // Don't handle disconnections if disposed

    final relay = _relays[url];
    if (relay == null) return;

    _info('Disconnected from relay: $url');

    // Emit relay status update
    _emitRelayStatus();

    // Cancel idle timer but keep connection listeners active to detect reconnection
    relay.idleTimer?.cancel();

    // If this was an intentional disconnection, clean up everything
    if (relay.intentionalDisconnection) {
      _info('Intentional disconnection from relay: $url');
      relay.connectionSubscription?.cancel();
      relay.messageSubscription?.cancel();
      relay.intentionalDisconnection = false; // Reset flag
      // Don't attempt reconnection for intentional disconnections
      return;
    }

    // For unintentional disconnections, keep listeners active to detect reconnection
    // The underlying WebSocket library will handle reconnection automatically
  }

  void _handleReconnecting(String url) {
    if (!mounted) return;

    final relay = _relays[url];
    if (relay == null) return;

    // Reset intentional disconnection flag in case it was set
    relay.intentionalDisconnection = false;

    // Emit relay status update
    _emitRelayStatus();
  }

  void _handleReconnection(String url) {
    if (!mounted) return;

    final relay = _relays[url];
    if (relay == null) return;

    _info('Reconnected to relay: $url');

    // Reset connection state
    relay.lastActivity = DateTime.now();
    relay.reconnectAttempts = 0;
    relay.intentionalDisconnection = false;

    // Reset idle timer
    _resetIdleTimer(url);

    // Emit relay status update
    _emitRelayStatus();

    // Re-send subscriptions immediately
    if (mounted) {
      _resendSubscriptions(url);
    }
  }

  void _resetIdleTimer(String url) {
    final relay = _relays[url];
    if (relay == null) return;

    relay.idleTimer?.cancel();
    relay.idleTimer = Timer(config.idleTimeout, () {
      // Mark as intentional disconnection since this is due to idle timeout
      relay.intentionalDisconnection = true;
      if (relay.socket != null) {
        relay.socket?.close();
      }
    });
  }

  Future<void> _resendSubscriptions(String url) async {
    final subscriptionsToResend = _subscriptions.values
        .where((subscription) => subscription.targetRelays.contains(url))
        .toList();

    for (final subscription in subscriptionsToResend) {
      final req = subscription.req;

      // Reset subscription state BEFORE sending REQ to ensure proper event processing
      subscription.eoseReceived.remove(url);
      subscription.connectedRelays.add(url);
      subscription.phase = SubscriptionPhase.eose;

      // Reset EOSE timer for reconnected subscription
      subscription.eoseTimer?.cancel();
      subscription.eoseTimer = Timer(
        config.responseTimeout,
        () => _flushEventBuffer(req.subscriptionId),
      );

      // Clear any existing buffered events from before disconnection
      subscription.bufferedEvents.clear();
      subscription.relaysForId.clear();

      // Now send the optimized REQ message
      _info('Re-sending optimized request $req to relay: $url');
      final optimizedReq = optimizeRequestForRelay(url, req);
      final message = jsonEncode([
        'REQ',
        req.subscriptionId,
        ...optimizedReq.toMaps(),
      ]);

      // Guard against sending to closed sockets (handles race conditions during reconnection)
      final relay = _relays[url];
      if (relay?.isConnected == true) {
        try {
          relay!.socket!.send(message);
        } catch (e) {
          _info(
            'ERROR: Failed to send message to $url after reconnection - $e',
          );
          // Socket might be in an inconsistent state, let it reconnect naturally
        }
      }
    }
  }

  @protected
  @visibleForTesting
  Map<String, RelayState> get relays => _relays;

  @protected
  @visibleForTesting
  Map<String, SubscriptionState> get subscriptions => _subscriptions;

  @protected
  @visibleForTesting
  Map<String, PublishState> get publishStates => _publishStates;
}

// Websocket pool state classes

class SubscriptionState {
  final Request req;
  final Set<String> targetRelays;
  final Set<String> connectedRelays;
  final Set<String> eoseReceived;
  final Set<Map<String, dynamic>> bufferedEvents;
  final Map<String, Set<String>> relaysForId =
      {}; // Track which relays sent each event

  SubscriptionPhase phase;
  Timer? eoseTimer;
  Timer? streamingBuffer;
  Completer<List<Map<String, dynamic>>>? queryCompleter; // For query() method

  SubscriptionState({required this.req, required this.targetRelays})
    : connectedRelays = <String>{},
      eoseReceived = <String>{},
      bufferedEvents = <Map<String, dynamic>>{},
      phase = SubscriptionPhase.eose;

  bool get allEoseReceived =>
      targetRelays.isEmpty || eoseReceived.containsAll(targetRelays);
}

class PublishState {
  final List<Map<String, dynamic>> events;
  final Set<String> targetRelays;
  final String publishId;
  final Set<String> pendingEventIds = <String>{};
  final Map<String, Set<String>> sentToRelays = {}; // eventId -> relay URLs
  final Map<String, Set<String>> pendingResponses =
      {}; // eventId -> relay URLs that responded
  final Map<String, Set<String>> failedRelays =
      {}; // eventId -> relay URLs that failed to connect
  final PublishRelayResponse response = PublishRelayResponse();

  Timer? timeoutTimer;
  Completer<PublishRelayResponse>? completer;

  PublishState({
    required this.events,
    required this.targetRelays,
    required this.publishId,
  });

  bool get allResponsesReceived {
    for (final eventId in pendingEventIds) {
      final sentTo = sentToRelays[eventId] ?? <String>{};
      final respondedFrom = pendingResponses[eventId] ?? <String>{};
      if (!sentTo.every((url) => respondedFrom.contains(url))) {
        return false;
      }
    }
    return true;
  }
}

class RelayState {
  WebSocket? socket;
  DateTime? lastActivity;
  int reconnectAttempts;
  Timer? reconnectTimer;
  Timer? idleTimer;
  StreamSubscription? connectionSubscription;
  StreamSubscription? messageSubscription;
  bool intentionalDisconnection = false;

  RelayState() : reconnectAttempts = 0;

  /// Use the underlying socket's actual connection state
  bool get isConnected {
    if (socket == null) return false;
    final connectionState = socket!.connection.state;
    return connectionState is Connected || connectionState is Reconnected;
  }

  bool get isConnecting {
    if (socket == null) return false;
    final connectionState = socket!.connection.state;
    return connectionState is Connecting || connectionState is Reconnecting;
  }

  bool get isDisconnected {
    if (socket == null) return true;
    final connectionState = socket!.connection.state;
    return connectionState is Disconnected || connectionState is Disconnecting;
  }
}

// Response classes

sealed class RelayResponse {}

enum SubscriptionPhase { eose, streaming }

final class EventRelayResponse extends RelayResponse {
  final SubscriptionPhase phase;

  // Originating request
  final Request req;

  final Set<Map<String, dynamic>> events;
  final Map<String, Set<String>> relaysForIds;

  EventRelayResponse({
    this.phase = SubscriptionPhase.eose,
    required this.req,
    required this.events,
    required this.relaysForIds,
  });
}

final class NoticeRelayResponse extends RelayResponse {
  final String message;
  final String relayUrl;

  NoticeRelayResponse({required this.message, required this.relayUrl});
}

final class PublishRelayResponse extends RelayResponse {
  // Need to wrap a PublishResponse as this class needs to extend RelayResponse
  final wrapped = PublishResponse();
  PublishRelayResponse();
}
