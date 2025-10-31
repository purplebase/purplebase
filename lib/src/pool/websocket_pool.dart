import 'dart:async';
import 'dart:convert';

import 'package:models/models.dart';
import 'package:purplebase/src/pool/connection/connection_coordinator.dart';
import 'package:purplebase/src/pool/connection/relay_connection.dart';
import 'package:purplebase/src/pool/optimization/event_buffer.dart';
import 'package:purplebase/src/pool/optimization/request_optimizer.dart';
import 'package:purplebase/src/pool/publish/publish_response.dart';
import 'package:purplebase/src/pool/state/connection_phase.dart';
import 'package:purplebase/src/pool/state/pool_state.dart';
import 'package:purplebase/src/pool/state/pool_state_notifier.dart';
import 'package:purplebase/src/pool/state/relay_event_notifier.dart';
import 'package:purplebase/src/pool/state/subscription_phase.dart';
import 'package:purplebase/src/pool/subscription/active_subscription.dart';
import 'package:purplebase/src/utils.dart';

/// WebSocket pool orchestrator
/// Coordinates connections, subscriptions, and message flow
class WebSocketPool {
  final StorageConfiguration config;
  final PoolStateNotifier stateNotifier;
  final RelayEventNotifier eventNotifier;

  // Core state
  final Map<String, RelayConnection> _connections = {};
  final Map<String, ActiveSubscription> _subscriptions = {};
  final Map<String, _PublishState> _publishStates = {};

  // Supporting components
  final ConnectionCoordinator _coordinator;
  final RequestOptimizer _optimizer;
  late final EventBuffer _eventBuffer;

  // Health check (triggered by main isolate heartbeat)
  DateTime? _lastHealthCheck;

  bool _disposed = false;

  WebSocketPool({
    required this.config,
    required this.stateNotifier,
    required this.eventNotifier,
  }) : _coordinator = ConnectionCoordinator(config: config),
       _optimizer = RequestOptimizer(maxEntries: 1000) {
    print('[pool] Initializing WebSocketPool');

    // Set up event buffer
    _eventBuffer = EventBuffer(
      batchWindow: config.streamingBufferWindow,
      onFlush: _handleEventBatch,
    );

    // Health checks are now triggered by heartbeat from main isolate
    _lastHealthCheck = DateTime.now();

    print('[pool] WebSocketPool initialized');
  }

  /// Perform health check (called by main isolate heartbeat)
  Future<void> performHealthCheck() async {
    if (_disposed) return;

    print(
      '[pool] Running health check (connections=${_connections.length}, subs=${_subscriptions.length})',
    );

    final result = _coordinator.performHealthCheck(
      _connections,
      _subscriptions,
      _lastHealthCheck,
    );

    _lastHealthCheck = DateTime.now();

    // Reconnect relays that need it
    for (final url in result.needReconnection) {
      final relay = _connections[url];
      if (relay != null) {
        _attemptReconnection(relay);
      }
    }

    // Emit updated state
    _emitState();
  }

  /// Attempt to reconnect a relay
  Future<void> _attemptReconnection(RelayConnection relay) async {
    print('[pool] Attempting reconnection to ${relay.url}');

    try {
      await _coordinator.ensureConnected(relay, _subscriptions);

      // Re-send subscriptions
      await _resendSubscriptions(relay.url);

      _emitState();
    } catch (e) {
      print('[pool] Reconnection failed for ${relay.url}: $e');
    }
  }

  /// Query relays
  Future<List<Map<String, dynamic>>> query(
    Request req, {
    RemoteSource source = const RemoteSource(),
  }) async {
    print(
      '[pool] query() - ${req.subscriptionId} (stream=${source.stream}, background=${source.background})',
    );

    // CRITICAL: If stream is not explicitly true, force background=false to prevent hangs
    if (source.stream != true && source.background == true) {
      source = source.copyWith(background: false);
    }

    // Get relay URLs
    final relayUrls = config
        .getRelays(source: source)
        .map(normalizeRelayUrl)
        .toSet();

    if (relayUrls.isEmpty) {
      print('[pool] No relays configured, returning empty result');
      return [];
    }

    print(
      '[pool] query() - ${req.subscriptionId} will use ${relayUrls.length} relay(s)',
    );

    // Set up completer for non-background queries
    final completer = source.background
        ? null
        : Completer<List<Map<String, dynamic>>>();

    // Send the request
    await send(
      req,
      relayUrls: relayUrls,
      queryCompleter: completer,
      isStreaming: source.stream == true,
    );

    // Return nothing for background queries
    if (source.background) {
      if (source.stream != true) {
        unsubscribe(req);
      }
      return [];
    }

    // Wait for results
    List<Map<String, dynamic>> events;
    try {
      events = await completer!.future;
    } finally {
      // Close subscription unless explicitly streaming
      if (source.stream != true) {
        unsubscribe(req);
      }
    }

    return events;
  }

  /// Send subscription request to relays
  Future<void> send(
    Request req, {
    Set<String> relayUrls = const {},
    Completer<List<Map<String, dynamic>>>? queryCompleter,
    bool isStreaming = false,
  }) async {
    if (relayUrls.isEmpty) return;

    print(
      '[pool] send() - ${req.subscriptionId} to ${relayUrls.length} relay(s), isStreaming=$isStreaming',
    );

    // Create subscription state
    final subscription = ActiveSubscription(
      request: req,
      targetRelays: relayUrls,
      isStreaming: isStreaming,
    );

    subscription.queryCompleter = queryCompleter;
    _subscriptions[req.subscriptionId] = subscription;

    // Set up EOSE timeout
    subscription.eoseTimer = Timer(
      config.responseTimeout,
      () => _flushSubscription(req.subscriptionId),
    );

    // Connect to relays and send requests
    final futures = <Future>[];
    for (final url in relayUrls) {
      final future = _ensureConnection(url)
          .then((_) {
            final relay = _connections[url];
            if (relay?.isConnected == true) {
              _sendSubscriptionToRelay(url, subscription);
            }
          })
          .catchError((error) {
            print('[pool] Failed to connect/send to $url: $error');
          });

      futures.add(future);
    }

    await Future.wait(futures);

    // Emit state
    _emitState();
  }

  /// Ensure connection to relay
  Future<void> _ensureConnection(String url) async {
    final normalizedUrl = normalizeRelayUrl(url);
    final relay = _connections.putIfAbsent(
      normalizedUrl,
      () => RelayConnection(url: normalizedUrl),
    );

    await _coordinator.ensureConnected(relay, _subscriptions);

    // Set up message listener if not already set
    if (relay.messageSubscription == null && relay.socket != null) {
      relay.messageSubscription = relay.socket!.messages.listen(
        (message) => _handleMessage(normalizedUrl, message),
      );
    }
  }

  /// Send subscription to a specific relay
  void _sendSubscriptionToRelay(String url, ActiveSubscription subscription) {
    final relay = _connections[url];
    if (relay == null || !relay.isConnected) return;

    // Optimize request for this relay
    final optimizedReq = _optimizer.optimize(
      url,
      subscription.request,
      isStreaming: subscription.isStreaming,
    );

    final message = jsonEncode([
      'REQ',
      subscription.request.subscriptionId,
      ...optimizedReq.toMaps(),
    ]);

    try {
      relay.socket!.send(message);
      relay.recordMessage();

      subscription.setRelayPhase(url, const SubscriptionActive());

      print('[pool] Sent REQ ${subscription.request.subscriptionId} to $url');
    } catch (e) {
      print('[pool] Failed to send REQ to $url: $e');
      subscription.setRelayPhase(url, SubscriptionFailed(e.toString()));
    }
  }

  /// Re-send subscriptions to a relay after reconnection
  Future<void> _resendSubscriptions(String url) async {
    final subscriptionsToResend = _subscriptions.values
        .where((sub) => sub.targetRelays.contains(url))
        .toList();

    if (subscriptionsToResend.isEmpty) {
      print('[pool] No subscriptions to resend to $url');
      return;
    }

    print(
      '[pool] Re-sending ${subscriptionsToResend.length} subscription(s) to $url',
    );

    for (final subscription in subscriptionsToResend) {
      subscription.markReconnection(url);
      _sendSubscriptionToRelay(url, subscription);
    }
  }

  /// Handle incoming message from relay
  void _handleMessage(String url, dynamic message) {
    final relay = _connections[url];
    if (relay == null) return;

    relay.recordMessage();

    try {
      final List<dynamic> data = jsonDecode(message);
      final messageType = data[0] as String;

      switch (messageType) {
        case 'EVENT':
          _handleEvent(url, data);
          break;
        case 'EOSE':
          _handleEose(url, data);
          break;
        case 'OK':
          _handleOk(url, data);
          break;
        case 'NOTICE':
          _handleNotice(url, data);
          break;
        case 'CLOSED':
          _handleClosed(url, data);
          break;
      }
    } catch (e) {
      print('[pool] Invalid message from $url: $e');
    }
  }

  /// Handle EVENT message
  void _handleEvent(String url, List<dynamic> data) {
    if (data.length < 3) return;

    final subscriptionId = data[1] as String;
    final event = data[2] as Map<String, dynamic>;
    final eventId = event['id'] as String?;

    if (eventId == null) return;

    print('[relay] EVENT from $url: ${event['kind']} ${eventId.substring(0, 8)}');

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) {
      print('[pool] EVENT for unknown subscription $subscriptionId');
      return;
    }

    // Add to subscription's buffer
    final isNew = subscription.addEvent(url, event);

    if (isNew) {
      // Record timestamp for optimization
      final eventTimestamp = event['created_at'] as int?;
      if (eventTimestamp != null) {
        _optimizer.recordEvent(
          url,
          subscription.request,
          DateTime.fromMillisecondsSinceEpoch(eventTimestamp * 1000),
        );
      }

      // Schedule flush based on phase
      if (subscription.phase == SubscriptionPhase.eose) {
        // Wait for EOSE
      } else {
        // Streaming - schedule batched flush
        _scheduleStreamingFlush(subscription);
      }
    }
  }

  /// Handle EOSE message
  void _handleEose(String url, List<dynamic> data) {
    if (data.length < 2) return;

    final subscriptionId = data[1] as String;
    final subscription = _subscriptions[subscriptionId];

    if (subscription == null) {
      print('[pool] EOSE for unknown subscription $subscriptionId');
      return;
    }

    subscription.markEoseReceived(url);

    print('[pool] EOSE received from $url for $subscriptionId');

    // Check if all target relays sent EOSE
    if (subscription.allEoseReceived &&
        subscription.phase == SubscriptionPhase.eose) {
      print('[pool] All EOSEs received for $subscriptionId, flushing buffer');
      subscription.eoseTimer?.cancel();
      _flushSubscription(subscriptionId);
    }
  }

  /// Handle OK message (publish response)
  void _handleOk(String url, List<dynamic> data) {
    if (data.length < 4) return;

    final eventId = data[1] as String;
    final accepted = data[2] as bool;
    final message = data.length > 3 ? data[3] as String? : null;

    // Find publish state for this event
    for (final publishState in _publishStates.values) {
      if (publishState.pendingEventIds.contains(eventId)) {
        publishState.recordResponse(url, eventId, accepted, message);

        if (publishState.isComplete) {
          publishState.timeoutTimer?.cancel();
          _completePublish(publishState);
        }
        break;
      }
    }
  }

  /// Handle NOTICE message
  void _handleNotice(String url, List<dynamic> data) {
    if (data.length < 2) return;

    final message = data[1] as String;
    eventNotifier.emitNotice(message: message, relayUrl: url);

    print('[pool] NOTICE from $url: $message');
  }

  /// Handle CLOSED message
  void _handleClosed(String url, List<dynamic> data) {
    if (data.length < 2) return;

    final subscriptionId = data[1] as String;
    final reason = data.length > 2 ? data[2] as String? : null;

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    print(
      '[pool] CLOSED from $url for $subscriptionId${reason != null ? ": $reason" : ""}',
    );

    // Mark for resubscription
    subscription.setRelayPhase(url, const SubscriptionResyncing());

    // Attempt to resubscribe
    _sendSubscriptionToRelay(url, subscription);
  }

  /// Flush subscription buffer
  void _flushSubscription(String subscriptionId) {
    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) return;

    print(
      '[pool] Flushing subscription $subscriptionId (${subscription.bufferedEvents.length} events)',
    );

    // Transition to streaming if was in EOSE phase
    if (subscription.phase == SubscriptionPhase.eose) {
      subscription.phase = SubscriptionPhase.streaming;

      // Complete query completer if exists
      if (subscription.queryCompleter != null &&
          !subscription.queryCompleter!.isCompleted) {
        subscription.queryCompleter!.complete(
          List.from(subscription.bufferedEvents),
        );
      }
    }

    // Emit events if buffer not empty
    if (subscription.bufferedEvents.isNotEmpty) {
      eventNotifier.emitEvents(
        req: subscription.request,
        events: Set.from(subscription.bufferedEvents),
        relaysForIds: Map.from(subscription.relaysForEventId),
      );

      subscription.clearBuffer();
    }
  }

  /// Schedule streaming flush
  void _scheduleStreamingFlush(ActiveSubscription subscription) {
    if (subscription.streamingFlushTimer?.isActive == true) return;

    subscription.streamingFlushTimer = Timer(
      config.streamingBufferWindow,
      () => _flushSubscription(subscription.request.subscriptionId),
    );
  }

  /// Handle event batch from EventBuffer
  void _handleEventBatch(
    Set<Map<String, dynamic>> events,
    Map<String, Set<String>> relaysForIds,
  ) {
    // This is called by EventBuffer, but we're not using it in this implementation
    // Events are handled per-subscription instead
  }

  /// Publish events to relays
  Future<PublishRelayResponse> publish(
    List<Map<String, dynamic>> events, {
    RemoteSource source = const RemoteSource(),
  }) async {
    if (events.isEmpty) {
      return PublishRelayResponse();
    }

    final relayUrls = config
        .getRelays(source: source)
        .map(normalizeRelayUrl)
        .toSet();

    if (relayUrls.isEmpty) {
      return PublishRelayResponse();
    }

    print(
      '[pool] Publishing ${events.length} event(s) to ${relayUrls.length} relay(s)',
    );

    // Create publish state
    final publishId = DateTime.now().millisecondsSinceEpoch.toString();
    final publishState = _PublishState(
      publishId: publishId,
      events: events,
      targetRelays: relayUrls,
    );

    _publishStates[publishId] = publishState;

    // Emit state to show publish in progress
    _emitState();

    // Set up timeout
    publishState.timeoutTimer = Timer(
      config.responseTimeout,
      () => _completePublish(publishState),
    );

    // Connect to relays and send events
    for (final url in relayUrls) {
      _ensureConnection(url)
          .then((_) {
            final relay = _connections[url];
            if (relay?.isConnected == true) {
              _sendEventsToRelay(url, publishState);
            }
          })
          .catchError((error) {
            print('[pool] Failed to publish to $url: $error');
            publishState.markRelayUnreachable(url);
          });
    }

    // Wait for completion
    return await publishState.completer.future;
  }

  /// Send events to a specific relay
  void _sendEventsToRelay(String url, _PublishState publishState) {
    final relay = _connections[url];
    if (relay == null || !relay.isConnected || relay.socket == null) {
      print('[pool] Cannot send events to $url - relay not ready');
      return;
    }

    for (final event in publishState.events) {
      final eventId = event['id'] as String?;
      if (eventId == null) continue;

      final message = jsonEncode(['EVENT', event]);

      try {
        relay.socket!.send(message);
        relay.recordMessage();
        publishState.markEventSent(url, eventId);
      } catch (e) {
        print('[pool] Failed to send event $eventId to $url: $e');
        publishState.markRelayFailed(url, eventId);
      }
    }
  }

  /// Complete publish operation
  void _completePublish(_PublishState publishState) {
    if (publishState.completer.isCompleted) return;

    final response = publishState.buildResponse();
    publishState.completer.complete(response);

    _publishStates.remove(publishState.publishId);
  }

  /// Unsubscribe from subscription
  void unsubscribe(Request req) {
    final subscriptionId = req.subscriptionId;
    final subscription = _subscriptions[subscriptionId];

    if (subscription == null) {
      print('[pool] unsubscribe() - subscription $subscriptionId not found');
      return;
    }

    print('[pool] unsubscribe() - closing $subscriptionId');

    // Send CLOSE message to relays
    final message = jsonEncode(['CLOSE', subscriptionId]);
    for (final url in subscription.targetRelays) {
      final relay = _connections[url];
      if (relay == null || !relay.isConnected || relay.socket == null) continue;

      try {
        relay.socket!.send(message);
        relay.recordMessage();
      } catch (e) {
        print('[pool] Failed to send CLOSE to $url: $e');
      }
    }

    // Clean up subscription
    subscription.dispose();
    _subscriptions.remove(subscriptionId);

    // Clean up idle relays
    _cleanupIdleRelays(subscription.targetRelays);

    // Emit state
    _emitState();
  }

  /// Clean up idle relays (no active subscriptions)
  void _cleanupIdleRelays(Set<String> relayUrls) {
    for (final url in relayUrls) {
      final hasActiveSubscriptions = _subscriptions.values.any(
        (sub) => sub.targetRelays.contains(url),
      );

      if (!hasActiveSubscriptions) {
        final relay = _connections[url];
        if (relay != null) {
          print('[pool] Cleaning up idle relay $url');
          _coordinator.cleanupIdleRelay(relay);
        }
      }
    }
  }

  /// Emit current pool state
  void _emitState() {
    stateNotifier.update(_buildPoolState());
  }

  /// Build current pool state
  PoolState _buildPoolState() {
    // Build connection states
    final connections = <String, RelayConnectionState>{};
    for (final entry in _connections.entries) {
      final url = entry.key;
      final relay = entry.value;

      final activeSubIds = _subscriptions.values
          .where((sub) => sub.targetRelays.contains(url))
          .map((sub) => sub.request.subscriptionId)
          .toSet();

      connections[url] = RelayConnectionState(
        url: url,
        phase: relay.phase,
        phaseStartedAt: relay.phaseStartedAt,
        reconnectAttempts: relay.reconnectAttempts,
        lastMessageAt: relay.lastMessageAt,
        lastError: relay.lastError,
        activeSubscriptionIds: activeSubIds,
      );
    }

    // Build subscription states
    final subscriptions = <String, SubscriptionState>{};
    for (final entry in _subscriptions.entries) {
      final subscriptionId = entry.key;
      final subscription = entry.value;

      subscriptions[subscriptionId] = SubscriptionState(
        subscriptionId: subscriptionId,
        targetRelays: subscription.targetRelays,
        isStreaming: subscription.isStreaming,
        relayStatus: Map.from(subscription.relayStatus),
        phase: subscription.phase,
        startedAt: subscription.startedAt,
        totalEventsReceived: subscription.totalEventsReceived,
      );
    }

    // Build publish states
    final publishes = <String, PublishOperation>{};
    for (final entry in _publishStates.entries) {
      final id = entry.key;
      final publishState = entry.value;

      // Build relay results from publish state
      // For PoolState, we track per-relay success (not per-event)
      final relayResults = <String, bool>{};
      for (final url in publishState.targetRelays) {
        // A relay is considered successful if ALL events were accepted
        bool allAccepted = true;
        for (final eventId in publishState.pendingEventIds) {
          final eventResponses = publishState.responses[eventId] ?? {};
          final accepted = eventResponses[url] ?? false;
          if (!accepted) {
            allAccepted = false;
            break;
          }
        }
        relayResults[url] = allAccepted;
      }

      publishes[id] = PublishOperation(
        id: id,
        targetRelays: publishState.targetRelays,
        relayResults: relayResults,
        startedAt: publishState.startTime,
      );
    }

    // Build health metrics
    final health = _buildHealthMetrics(connections, subscriptions);

    return PoolState(
      connections: connections,
      subscriptions: subscriptions,
      publishes: publishes,
      health: health,
      timestamp: DateTime.now(),
    );
  }

  /// Build health metrics
  HealthMetrics _buildHealthMetrics(
    Map<String, RelayConnectionState> connections,
    Map<String, SubscriptionState> subscriptions,
  ) {
    final connectedCount = connections.values
        .where((c) => c.phase is Connected)
        .length;
    final disconnectedCount = connections.values
        .where((c) => c.phase is Disconnected)
        .length;
    final reconnectingCount = connections.values
        .where((c) => c.phase is Reconnecting)
        .length;

    final fullyActive = subscriptions.values.where((s) {
      return s.targetRelays.every((url) {
        final status = s.relayStatus[url];
        final conn = connections[url];
        return status?.phase is SubscriptionActive && conn?.phase is Connected;
      });
    }).length;

    final partiallyActive = subscriptions.values.where((s) {
      final activeCount = s.targetRelays.where((url) {
        final status = s.relayStatus[url];
        final conn = connections[url];
        return status?.phase is SubscriptionActive && conn?.phase is Connected;
      }).length;
      return activeCount > 0 && activeCount < s.targetRelays.length;
    }).length;

    final failed = subscriptions.values.where((s) {
      return s.targetRelays.every((url) {
        final status = s.relayStatus[url];
        return status?.phase is SubscriptionFailed;
      });
    }).length;

    return HealthMetrics(
      totalConnections: connections.length,
      connectedCount: connectedCount,
      disconnectedCount: disconnectedCount,
      reconnectingCount: reconnectingCount,
      totalSubscriptions: subscriptions.length,
      fullyActiveSubscriptions: fullyActive,
      partiallyActiveSubscriptions: partiallyActive,
      failedSubscriptions: failed,
      lastHealthCheckAt: _lastHealthCheck,
    );
  }

  /// Dispose pool
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    print('[pool] Disposing WebSocketPool');

    // Cancel all subscriptions
    for (final subscription in _subscriptions.values) {
      subscription.dispose();
    }

    // Cancel all publishes
    for (final publishState in _publishStates.values) {
      publishState.timeoutTimer?.cancel();
      if (!publishState.completer.isCompleted) {
        publishState.completer.complete(PublishRelayResponse());
      }
    }

    // Close all connections
    for (final relay in _connections.values) {
      relay.dispose();
    }

    // Clear state
    _connections.clear();
    _subscriptions.clear();
    _publishStates.clear();

    // Dispose utilities
    _eventBuffer.dispose();

    print('[pool] WebSocketPool disposed');
  }
}

/// Publish state tracking
class _PublishState {
  final String publishId;
  final List<Map<String, dynamic>> events;
  final Set<String> targetRelays;
  final DateTime startTime;

  final Set<String> pendingEventIds = {};
  final Map<String, Set<String>> sentToRelays = {}; // eventId -> relays
  final Map<String, Set<String>> failedRelays = {}; // eventId -> relays
  final Map<String, Map<String, bool>> responses =
      {}; // eventId -> {relayUrl -> accepted}

  Timer? timeoutTimer;
  final Completer<PublishRelayResponse> completer = Completer();

  _PublishState({
    required this.publishId,
    required this.events,
    required this.targetRelays,
  }) : startTime = DateTime.now() {
    // Extract event IDs
    for (final event in events) {
      final eventId = event['id'] as String?;
      if (eventId != null) {
        pendingEventIds.add(eventId);
      }
    }
  }

  void markEventSent(String url, String eventId) {
    sentToRelays.putIfAbsent(eventId, () => {}).add(url);
  }

  void markRelayFailed(String url, String eventId) {
    failedRelays.putIfAbsent(eventId, () => {}).add(url);
  }

  void markRelayUnreachable(String url) {
    for (final eventId in pendingEventIds) {
      markRelayFailed(url, eventId);
    }
  }

  void recordResponse(
    String url,
    String eventId,
    bool accepted,
    String? message,
  ) {
    responses.putIfAbsent(eventId, () => {})[url] = accepted;
  }

  bool get isComplete {
    for (final eventId in pendingEventIds) {
      final sent = sentToRelays[eventId] ?? {};
      final responded = responses[eventId]?.keys.toSet() ?? {};

      if (!sent.every((url) => responded.contains(url))) {
        return false;
      }
    }
    return true;
  }

  PublishRelayResponse buildResponse() {
    final response = PublishRelayResponse();

    // Track unreachable relays
    final allSent = sentToRelays.values.expand((urls) => urls).toSet();
    final allFailed = failedRelays.values.expand((urls) => urls).toSet();
    final unreachable = targetRelays.difference(allSent).union(allFailed);

    response.wrapped.unreachableRelayUrls.addAll(unreachable);

    // Add results for each event
    for (final eventId in pendingEventIds) {
      final eventResponses = responses[eventId] ?? {};

      // Add successful/responded relays
      for (final entry in eventResponses.entries) {
        response.wrapped.addEvent(
          eventId,
          relayUrl: entry.key,
          accepted: entry.value,
        );
      }

      // Add failed relays (offline, connection errors, etc.)
      final eventFailed = failedRelays[eventId] ?? {};
      for (final url in eventFailed) {
        // Only add if not already in responses (avoid duplicates)
        if (!eventResponses.containsKey(url)) {
          response.wrapped.addEvent(
            eventId,
            relayUrl: url,
            accepted: false,
          );
        }
      }

      // Add relays we never sent to (connection failed before sending)
      for (final url in targetRelays) {
        final sent = sentToRelays[eventId]?.contains(url) ?? false;
        final hasResponse = eventResponses.containsKey(url);
        final hasFailed = eventFailed.contains(url);
        
        if (!sent && !hasResponse && !hasFailed) {
          response.wrapped.addEvent(
            eventId,
            relayUrl: url,
            accepted: false,
          );
        }
      }
    }

    return response;
  }
}
