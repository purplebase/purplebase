import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:models/models.dart';
import 'package:purplebase/src/pool_notifiers.dart';
import 'package:purplebase/src/relay_status_types.dart';
import 'package:purplebase/src/utils.dart';
import 'package:web_socket_client/web_socket_client.dart';

class WebSocketPool {
  final Map<String, RelayState> _relays = {};
  final Map<String, SubscriptionState> _subscriptions = {};
  final Map<String, PublishState> _publishStates = {};
  final StorageConfiguration config;

  // Notifiers
  final RelayEventNotifier eventNotifier;
  final PoolStatusNotifier statusNotifier;

  // LRU cache for relay-request timestamp optimization (max 1000 entries)
  final Map<String, DateTime> _relayRequestTimestamps = {};
  final List<String> _timestampKeys = []; // For LRU ordering
  static const int _maxTimestampEntries = 1000;

  // Health check timer for detecting disconnected relays
  Timer? _healthCheckTimer;
  static const Duration _healthCheckInterval = Duration(seconds: 30);

  bool _disposed = false;

  WebSocketPool({
    required this.config,
    required this.eventNotifier,
    required this.statusNotifier,
  }) {
    // Start health check timer to detect stale connections
    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) {
      _checkConnectionHealth();
    });
  }

  /// Build and emit current pool status
  void _emitPoolStatus() {
    final status = _buildPoolStatus();
    statusNotifier.update(status);
  }

  /// Build current pool status
  PoolStatus _buildPoolStatus() {
    // Build relay connection info
    final connections = <String, RelayConnectionInfo>{};

    for (final entry in _relays.entries) {
      final url = entry.key;
      final relay = entry.value;

      // Determine connection state
      RelayConnectionState state;

      if (relay.isConnected) {
        // If relay has reconnected before, mark as "reconnected"
        state = relay.hasReconnected
            ? RelayConnectionState.reconnected
            : RelayConnectionState.connected;
      } else if (relay.isConnecting) {
        state = RelayConnectionState.connecting;
      } else {
        state = RelayConnectionState.disconnected;
      }

      connections[url] = RelayConnectionInfo(
        url: url,
        state: state,
        lastActivity: relay.lastActivity,
        reconnectAttempts: relay.reconnectAttempts,
        lastStatusChange: relay.lastStatusChange,
      );
    }

    // Build subscription info
    final subscriptions = <String, SubscriptionInfo>{};
    for (final entry in _subscriptions.entries) {
      final subscriptionId = entry.key;
      final subscription = entry.value;

      // Convert ALL request filters to JSON for display
      List<Map<String, dynamic>>? filtersJson;
      try {
        if (subscription.req.filters.isNotEmpty) {
          filtersJson = subscription.req.filters.map((filter) {
            return <String, dynamic>{
              if (filter.ids.isNotEmpty) 'ids': filter.ids.toList(),
              if (filter.authors.isNotEmpty) 'authors': filter.authors.toList(),
              if (filter.kinds.isNotEmpty) 'kinds': filter.kinds.toList(),
              if (filter.tags.isNotEmpty)
                'tags': filter.tags.map((k, v) => MapEntry(k, v.toList())),
              if (filter.since != null)
                'since': filter.since!.toIso8601String(),
              if (filter.until != null)
                'until': filter.until!.toIso8601String(),
              if (filter.limit != null) 'limit': filter.limit,
              if (filter.search != null) 'search': filter.search,
            };
          }).toList();
        }
      } catch (e) {
        // Ignore filter serialization errors
      }

      subscriptions[subscriptionId] = SubscriptionInfo(
        subscriptionId: subscriptionId,
        targetRelays: subscription.targetRelays,
        connectedRelays: subscription.connectedRelays,
        eoseReceived: subscription.eoseReceived,
        phase: subscription.phase,
        startTime: subscription.startTime,
        requestFilters: filtersJson,
        reconnectionCount: Map.from(subscription.reconnectionCount),
        lastReconnectTime: Map.from(subscription.lastReconnectTime),
        resyncing: Set.from(subscription.resyncing),
      );
    }

    // Build publish info
    final publishes = <String, PublishInfo>{};
    for (final entry in _publishStates.entries) {
      final id = entry.key;
      final publishState = entry.value;

      publishes[id] = PublishInfo(
        id: id,
        targetRelays: publishState.targetRelays.toList(),
        relayResults: {},
        startTime: publishState.startTime,
      );
    }

    // Preserve existing errors from status notifier
    final currentErrors = statusNotifier.mounted
        ? statusNotifier.currentState.recentErrors
        : <ErrorEntry>[];

    return PoolStatus(
      connections: connections,
      subscriptions: subscriptions,
      publishes: publishes,
      recentErrors: currentErrors,
      lastUpdated: DateTime.now(),
    );
  }

  /// Log an error
  void _logError(
    String message, {
    String? relayUrl,
    String? subscriptionId,
    String? eventId,
  }) {
    statusNotifier.logError(
      message,
      relayUrl: relayUrl,
      subscriptionId: subscriptionId,
      eventId: eventId,
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

    // Normalize all relay URLs to ensure consistent formatting
    final normalizedUrls = relayUrls.map(normalizeRelayUrl).toSet();

    // Create subscription state
    final subscription = SubscriptionState(
      req: req,
      targetRelays: normalizedUrls,
    );
    _subscriptions[req.subscriptionId] = subscription;

    // Emit pool status update
    _emitPoolStatus();

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
    for (final url in normalizedUrls) {
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
                _logError(
                  'Failed to send request ${req.subscriptionId} to relay $url - $e',
                  relayUrl: url,
                  subscriptionId: req.subscriptionId,
                );
                // Continue with other relays
              }
            }
          })
          .catchError((error) {
            print(error);
            _logError(
              'Failed to send request ${req.subscriptionId} to relay $url - $error',
              relayUrl: url,
              subscriptionId: req.subscriptionId,
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
    // Normalize relay URLs from config
    final relayUrls = config
        .getRelays(source: source)
        .map(normalizeRelayUrl)
        .toSet();

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
      // Close subscription for background queries unless explicitly streaming
      if (source.stream != true) {
        unsubscribe(req);
      }
      return [];
    }

    List<Map<String, dynamic>> events;
    try {
      events = await completer.future;
    } finally {
      // Close subscription by default unless explicitly streaming
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
    // Normalize relay URLs from config
    final relayUrls = config
        .getRelays(source: source)
        .map(normalizeRelayUrl)
        .toSet();

    if (relayUrls.isEmpty || events.isEmpty) {
      return PublishRelayResponse();
    }

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
                  _logError(
                    'Failed to send event $eventId to relay $url - $e',
                    relayUrl: url,
                    eventId: eventId,
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
          _logError(
            'Failed to send CLOSE to relay $url - $e',
            relayUrl: url,
            subscriptionId: subscriptionId,
          );
          // Continue with other relays
        }
      }
    }

    // Clean up subscription
    subscription.streamingBuffer?.cancel();
    subscription.eoseTimer?.cancel();
    _subscriptions.remove(subscriptionId);

    // Emit pool status update
    _emitPoolStatus();

    // Check if any relay has no more active subscriptions and close if idle
    _cleanupIdleRelays(subscription.targetRelays);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;

    // Cancel health check timer
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;

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
  }

  // Keep private methods below this comment

  /// Validate that a relay connection is ready to send messages
  bool _isRelayReadyToSend(String url) {
    final relay = _relays[url];
    if (relay == null) return false;
    if (relay.socket == null) return false;
    if (!relay.isConnected) return false;
    if (relay.intentionalDisconnection) return false;
    return true;
  }

  /// Check connection health and force reconnection for stale connections
  void _checkConnectionHealth() {
    if (_disposed) return;

    final now = DateTime.now();
    for (final entry in _relays.entries) {
      final url = entry.key;
      final relay = entry.value;

      // Check if there are active subscriptions for this relay
      final hasActiveSubscriptions = _subscriptions.values.any(
        (sub) => sub.targetRelays.contains(url),
      );

      // Skip relays with no active work
      if (!hasActiveSubscriptions) continue;

      // CASE 1: Disconnected with active subscriptions
      if (relay.isDisconnected && !relay.isConnecting) {
        final timeSinceDisconnect = now.difference(relay.lastStatusChange);

        // If disconnected for more than 30 seconds, attempt reconnection
        if (timeSinceDisconnect > Duration(seconds: 30)) {
          final activeSubCount = _subscriptions.values
              .where((s) => s.targetRelays.contains(url))
              .length;

          _logError(
            'Relay $url has been disconnected for ${timeSinceDisconnect.inSeconds}s with $activeSubCount active subscription(s), attempting reconnection',
            relayUrl: url,
          );

          _ensureConnection(url).catchError((error) {
            _logError('Failed to reconnect to $url: $error', relayUrl: url);
          });
        }
      }
      // CASE 2: Stuck in "connecting" state
      else if (relay.isConnecting) {
        final timeSinceStatusChange = now.difference(relay.lastStatusChange);

        // If stuck connecting for more than 2x responseTimeout, force reset
        if (timeSinceStatusChange > config.responseTimeout * 2) {
          _logError(
            'Relay $url stuck connecting for ${timeSinceStatusChange.inSeconds}s, forcing reset',
            relayUrl: url,
          );

          // Close and let it reconnect cleanly
          relay.intentionalDisconnection = false;
          try {
            relay.socket?.close();
          } catch (e) {
            // Ignore close errors
          }

          // Try fresh connection after brief delay
          Future.delayed(Duration(milliseconds: 500), () {
            if (!_disposed) {
              _ensureConnection(url).catchError((error) {
                _logError(
                  'Failed to reconnect to $url after reset: $error',
                  relayUrl: url,
                );
              });
            }
          });
        }
      }
    }
  }

  /// Close relay connections that have no active subscriptions
  void _cleanupIdleRelays(Set<String> relayUrls) {
    // Normalize all URLs before processing
    final normalizedUrls = relayUrls.map(normalizeRelayUrl).toSet();
    for (final url in normalizedUrls) {
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
    // Normalize URL when accessing relay map
    final normalizedUrl = normalizeRelayUrl(url);
    final relay = _relays.putIfAbsent(normalizedUrl, () => RelayState());

    if (relay.isConnected || relay.isConnecting) {
      return;
    }

    await _connect(normalizedUrl);
  }

  Future<void> _connect(String url) async {
    if (_disposed) return; // Don't connect if disposed

    // URL should already be normalized from _ensureConnection, but ensure it
    final normalizedUrl = normalizeRelayUrl(url);
    final relay = _relays[normalizedUrl]!;

    // If we already have a connected socket, don't create another one
    if (relay.isConnected) return;

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
      relay.lastStatusChange = DateTime.now();
      relay.reconnectAttempts = 0;

      _resetIdleTimer(normalizedUrl);
      _setupSocketListeners(normalizedUrl, socket);

      // Wait for connection to be established, but with timeout to prevent hanging
      final connectionFuture = socket.connection.firstWhere(
        (state) => state is Connected,
        orElse: () => throw TimeoutException('Connection timeout'),
      );

      await connectionFuture.timeout(config.responseTimeout);

      // Verify we're still not disposed before proceeding
      if (_disposed) {
        socket.close();
        return;
      }

      // Emit pool status update
      _emitPoolStatus();

      // Re-send active subscriptions to this relay
      await _resendSubscriptions(normalizedUrl);
    } catch (e) {
      _logError(
        'Failed to connect to relay $normalizedUrl - $e',
        relayUrl: normalizedUrl,
      );
      // Connection failed - rethrow so that the publish method can handle it
      rethrow;
    }
  }

  void _setupSocketListeners(String url, WebSocket socket) {
    // Normalize URL when accessing relay map
    final normalizedUrl = normalizeRelayUrl(url);
    final relay = _relays[normalizedUrl]!;

    // Listen to connection state changes
    relay.connectionSubscription = socket.connection.listen((state) {
      if (state is Disconnected) {
        _handleDisconnection(normalizedUrl);
      } else if (state is Reconnected) {
        _handleReconnection(normalizedUrl);
      } else if (state is Connected) {
        // Handle Connected state - might occur during reconnection scenarios
        // Only treat as reconnection if socket already had activity before
        if (relay.lastActivity != null && relay.hasReconnected) {
          // This is a reconnection that reported as Connected instead of Reconnected
          _handleReconnection(normalizedUrl);
        }
        // Otherwise it's the initial connection, handled by _connect() method
      } else if (state is Reconnecting) {
        _handleReconnecting(normalizedUrl);
      }
    });

    // Listen to messages
    relay.messageSubscription = socket.messages.listen(
      (message) async => await _handleMessage(normalizedUrl, message),
    );
  }

  Future<void> _handleMessage(String url, dynamic message) async {
    // Normalize URL when accessing relay map
    final normalizedUrl = normalizeRelayUrl(url);
    final relay = _relays[normalizedUrl]!;
    relay.lastActivity = DateTime.now();
    _resetIdleTimer(normalizedUrl);

    try {
      final List<dynamic> data = jsonDecode(message);
      final messageType = data[0] as String;

      switch (messageType) {
        case 'EVENT':
          handleEvent(normalizedUrl, data);
          break;
        case 'EOSE':
          await _handleEose(normalizedUrl, data);
          break;
        case 'OK':
          _handleOk(normalizedUrl, data);
          break;
        case 'NOTICE':
          _handleNotice(normalizedUrl, data);
          break;
      }
    } catch (e) {
      // Invalid message format, ignore
    }
  }

  @protected
  @visibleForTesting
  void handleEvent(String url, List<dynamic> data) {
    // Normalize URL for consistency
    final normalizedUrl = normalizeRelayUrl(url);
    if (data.length < 3) return;

    final subscriptionId = data[1] as String;
    final event = data[2] as Map<String, dynamic>;
    final eventId = event['id'] as String?;

    if (eventId == null) return;

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    // Always track which relay sent this event (use normalized URL)
    subscription.relaysForId
        .putIfAbsent(eventId, () => <String>{})
        .add(normalizedUrl);

    // Check if this event is already buffered for this subscription
    final alreadyBuffered = subscription.bufferedEvents.any(
      (bufferedEvent) => bufferedEvent['id'] == eventId,
    );

    if (alreadyBuffered) {
      return; // Event already in buffer for this subscription
    }

    // Track latest timestamp for this relay-request pair (use normalized URL)
    final eventTimestamp = event['created_at'] as int?;
    if (eventTimestamp != null) {
      _storeRelayRequestTimestamp(
        normalizedUrl,
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
    // Normalize URL for consistency
    final normalizedUrl = normalizeRelayUrl(url);
    if (data.length < 2) return;

    final subscriptionId = data[1] as String;
    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    subscription.eoseReceived.add(normalizedUrl);

    // Mark relay as no longer re-syncing (finished catching up)
    subscription.resyncing.remove(normalizedUrl);

    if (subscription.allEoseReceived &&
        subscription.phase == SubscriptionPhase.eose) {
      // All target relays sent EOSE, cancel timeout timer
      subscription.eoseTimer?.cancel();
      _flushEventBuffer(subscriptionId);
    }

    // Emit status update to reflect re-sync completion
    _emitPoolStatus();
  }

  void _handleOk(String url, List<dynamic> data) {
    // Normalize URL for consistency
    final normalizedUrl = normalizeRelayUrl(url);
    if (data.length < 4) return;

    final eventId = data[1] as String;
    final accepted = data[2] as bool;
    final message = data.length > 3 ? data[3] as String? : null;

    // Find publish states that are waiting for this event
    for (final publishState in [..._publishStates.values]) {
      if (publishState.pendingEventIds.contains(eventId)) {
        // Check if this relay was supposed to receive this event
        final relaysForEvent = publishState.sentToRelays[eventId];
        if (relaysForEvent != null && relaysForEvent.contains(normalizedUrl)) {
          publishState.response.wrapped.addEvent(
            eventId,
            relayUrl: normalizedUrl,
            accepted: accepted,
            message: message,
          );

          // Remove this relay from pending for this event
          publishState.pendingResponses
              .putIfAbsent(eventId, () => <String>{})
              .add(normalizedUrl);

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
    // Normalize URL for consistency
    final normalizedUrl = normalizeRelayUrl(url);
    if (_disposed || data.length < 2) return;
    final message = data[1] as String;
    eventNotifier.emitNotice(
      NoticeRelayResponse(message: message, relayUrl: normalizedUrl),
    );
  }

  // Used to emit EOSE and streaming-buffered events
  Future<void> _flushEventBuffer(String subscriptionId) async {
    if (_disposed) return;

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

    // Only emit events if there are buffered events
    if (subscription.bufferedEvents.isNotEmpty) {
      // Create copies to avoid clearing the Set while it's being used
      final eventsCopy = Set<Map<String, dynamic>>.from(
        subscription.bufferedEvents,
      );
      final relaysCopy = Map<String, Set<String>>.from(
        subscription.relaysForId,
      );

      eventNotifier.emitEvents(
        EventRelayResponse(
          req: subscription.req,
          events: eventsCopy,
          relaysForIds: relaysCopy,
        ),
      );

      subscription.bufferedEvents.clear();
      subscription.relaysForId.clear();
    }
  }

  Future<void> _flushPublishBuffer(String publishId) async {
    if (_disposed) return;

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

      publishState.completer!.complete(publishState.response);
    }

    publishState.timeoutTimer?.cancel();
    _publishStates.remove(publishId);
  }

  void _scheduleStreamingFlush(String subscriptionId) {
    if (_disposed) return;

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
    // Normalize URL for consistency
    final normalizedUrl = normalizeRelayUrl(url);
    if (_disposed) return; // Don't handle disconnections if disposed

    final relay = _relays[normalizedUrl];
    if (relay == null) return;

    // Update status change timestamp
    relay.lastStatusChange = DateTime.now();

    // Remove this relay from all active subscriptions' connectedRelays
    for (final subscription in _subscriptions.values) {
      if (subscription.targetRelays.contains(normalizedUrl)) {
        subscription.connectedRelays.remove(normalizedUrl);
      }
    }

    // Emit pool status update
    _emitPoolStatus();

    // Cancel idle timer but keep connection listeners active to detect reconnection
    relay.idleTimer?.cancel();

    // If this was an intentional disconnection, clean up everything
    if (relay.intentionalDisconnection) {
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
    // Normalize URL for consistency
    final normalizedUrl = normalizeRelayUrl(url);
    if (_disposed) return;

    final relay = _relays[normalizedUrl];
    if (relay == null) return;

    // Update status change timestamp
    relay.lastStatusChange = DateTime.now();

    // Reset intentional disconnection flag in case it was set
    relay.intentionalDisconnection = false;

    // Emit pool status update
    _emitPoolStatus();
  }

  void _handleReconnection(String url) {
    // Normalize URL for consistency
    final normalizedUrl = normalizeRelayUrl(url);
    if (_disposed) return;

    final relay = _relays[normalizedUrl];
    if (relay == null) return;

    // Mark that this relay has reconnected (not initial connection)
    relay.hasReconnected = true;

    // Reset connection state
    relay.lastActivity = DateTime.now();
    relay.lastStatusChange = DateTime.now();
    relay.reconnectAttempts = 0;
    relay.intentionalDisconnection = false;

    // Reset idle timer
    _resetIdleTimer(normalizedUrl);

    // DON'T emit status yet - wait until subscriptions are successfully re-sent

    // Re-send subscriptions and await completion with error handling
    if (!_disposed) {
      _resendSubscriptions(normalizedUrl)
          .then((_) {
            // Successfully re-sent all subscriptions, now emit status
            if (!_disposed) {
              _emitPoolStatus();
            }
          })
          .catchError((error, stackTrace) {
            _logError(
              'Failed to resend subscriptions after reconnection to $normalizedUrl - $error',
              relayUrl: normalizedUrl,
            );

            // Force disconnect to trigger another reconnection attempt
            // This ensures we don't show as "connected" when subscriptions failed
            if (!_disposed && relay.socket != null) {
              relay.intentionalDisconnection = false; // Allow reconnection
              try {
                relay.socket?.close();
              } catch (e) {
                // Ignore errors during forced close
              }
            }

            // Emit status to reflect the failure
            if (!_disposed) {
              _emitPoolStatus();
            }
          });
    }
  }

  void _resetIdleTimer(String url) {
    // Normalize URL for consistency
    final normalizedUrl = normalizeRelayUrl(url);
    final relay = _relays[normalizedUrl];
    if (relay == null) return;

    relay.idleTimer?.cancel();
    relay.idleTimer = Timer(config.idleTimeout, () {
      // Check if there are active subscriptions for this relay
      final hasActiveSubscriptions = _subscriptions.values.any(
        (sub) => sub.targetRelays.contains(normalizedUrl),
      );

      // Only disconnect if there are no active subscriptions
      if (!hasActiveSubscriptions) {
        // Mark as intentional disconnection since this is due to idle timeout
        relay.intentionalDisconnection = true;
        if (relay.socket != null) {
          relay.socket?.close();
        }
      }
      // If there are active subscriptions, don't disconnect
      // The relay will stay connected until subscriptions are closed
    });
  }

  Future<void> _resendSubscriptions(String url) async {
    // Normalize URL for consistency
    final normalizedUrl = normalizeRelayUrl(url);

    final subscriptionsToResend = _subscriptions.values
        .where(
          (subscription) => subscription.targetRelays.contains(normalizedUrl),
        )
        .toList();

    // If no subscriptions to resend, return early (success)
    if (subscriptionsToResend.isEmpty) {
      return;
    }

    // Wait for relay to become ready, with timeout
    final startTime = DateTime.now();
    while (!_isRelayReadyToSend(normalizedUrl)) {
      final elapsed = DateTime.now().difference(startTime);
      if (elapsed > config.responseTimeout) {
        throw Exception(
          'Timeout waiting for relay $normalizedUrl to become ready (${elapsed.inSeconds}s)',
        );
      }
      await Future.delayed(Duration(milliseconds: 100));
    }

    final errors = <String>[];

    for (final subscription in subscriptionsToResend) {
      final req = subscription.req;

      // Track reconnection for this relay
      subscription.resyncing.add(normalizedUrl);
      subscription.reconnectionCount[normalizedUrl] =
          (subscription.reconnectionCount[normalizedUrl] ?? 0) + 1;
      subscription.lastReconnectTime[normalizedUrl] = DateTime.now();

      // Reset subscription state for THIS relay only
      subscription.eoseReceived.remove(normalizedUrl);
      subscription.connectedRelays.add(normalizedUrl);

      // Only reset phase to EOSE if ALL relays were disconnected
      // If other relays are still connected and streaming, keep streaming
      final anyOtherRelayStreaming = subscription.connectedRelays
          .where((r) => r != normalizedUrl)
          .any((r) => subscription.eoseReceived.contains(r));

      if (!anyOtherRelayStreaming) {
        subscription.phase = SubscriptionPhase.eose;

        // Reset EOSE timer only if this is the only relay
        subscription.eoseTimer?.cancel();
        subscription.eoseTimer = Timer(
          config.responseTimeout,
          () => _flushEventBuffer(req.subscriptionId),
        );
      }
      // else: keep streaming, this relay will catch up

      // DON'T clear buffered events - other relays might still be sending
      // Events are deduplicated by ID, so duplicates won't be an issue

      // Now send the optimized REQ message
      final optimizedReq = optimizeRequestForRelay(normalizedUrl, req);
      final message = jsonEncode([
        'REQ',
        req.subscriptionId,
        ...optimizedReq.toMaps(),
      ]);

      final relay = _relays[normalizedUrl];
      try {
        relay!.socket!.send(message);
        // Update last activity after successful send
        relay.lastActivity = DateTime.now();
      } catch (e) {
        final error =
            'Failed to send subscription ${req.subscriptionId} to $normalizedUrl: $e';
        errors.add(error);
        _logError(
          error,
          relayUrl: normalizedUrl,
          subscriptionId: req.subscriptionId,
        );
        // Don't rethrow yet - try to send other subscriptions
      }
    }

    // If any errors occurred, throw to trigger error handling in caller
    if (errors.isNotEmpty) {
      throw Exception(
        'Failed to resend ${errors.length} subscription(s) to $normalizedUrl: ${errors.join('; ')}',
      );
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
  final DateTime startTime;

  // Track reconnection state per relay
  final Map<String, int> reconnectionCount = {}; // relay -> reconnect count
  final Map<String, DateTime> lastReconnectTime = {}; // relay -> timestamp
  final Set<String> resyncing = {}; // relays currently re-syncing

  SubscriptionPhase phase;
  Timer? eoseTimer;
  Timer? streamingBuffer;
  Completer<List<Map<String, dynamic>>>? queryCompleter; // For query() method

  SubscriptionState({required this.req, required this.targetRelays})
    : connectedRelays = <String>{},
      eoseReceived = <String>{},
      bufferedEvents = <Map<String, dynamic>>{},
      phase = SubscriptionPhase.eose,
      startTime = DateTime.now();

  bool get allEoseReceived =>
      targetRelays.isEmpty || eoseReceived.containsAll(targetRelays);
}

class PublishState {
  final List<Map<String, dynamic>> events;
  final Set<String> targetRelays;
  final String publishId;
  final DateTime startTime;
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
  }) : startTime = DateTime.now();

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
  bool hasReconnected = false; // Track if this relay has reconnected
  DateTime lastStatusChange; // Track when state last changed

  RelayState() : reconnectAttempts = 0, lastStatusChange = DateTime.now();

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
