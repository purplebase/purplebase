import 'dart:async';

import 'package:models/models.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:purplebase/src/notifiers.dart';
import 'package:purplebase/src/pool/connection/relay_agent.dart';
import 'package:purplebase/src/pool/publish/publish_response.dart';
import 'package:purplebase/src/pool/state/connection_phase.dart' as pool_phase;
import 'package:purplebase/src/pool/state/pool_state.dart';
import 'package:purplebase/src/pool/state/pool_state_notifier.dart';
import 'package:purplebase/src/pool/state/relay_event_notifier.dart';
import 'package:purplebase/src/pool/state/subscription_phase.dart';
import 'package:purplebase/src/pool/subscription/subscription_buffer.dart';
import 'package:purplebase/src/utils.dart';

/// WebSocket pool - thin coordinator that manages relay agents
/// Agents handle connection lifecycle, pool handles subscriptions and batching
class WebSocketPool {
  final StorageConfiguration config;
  final PoolStateNotifier stateNotifier;
  final RelayEventNotifier eventNotifier;
  final DebugNotifier? debugNotifier;

  // Relay agents (normalized URL -> agent)
  final Map<String, RelayAgent> _agents = {};

  // Subscription buffers (subscription ID -> buffer)
  final Map<String, SubscriptionBuffer> _subscriptions = {};

  bool _disposed = false;

  WebSocketPool({
    required this.config,
    required this.stateNotifier,
    required this.eventNotifier,
    this.debugNotifier,
  });

  /// Query relays
  Future<List<Map<String, dynamic>>> query(
    Request req, {
    RemoteSource source = const RemoteSource(),
  }) async {
    // CRITICAL: If stream is false, force background=false to prevent hangs
    if (!source.stream && source.background == true) {
      source = source.copyWith(background: false);
    }

    // Get relay URLs
    final relayUrls = config
        .getRelays(source: source)
        .map(normalizeRelayUrl)
        .toSet();

    if (relayUrls.isEmpty) {
      return [];
    }

    // Set up completer for non-background queries
    final completer = source.background
        ? null
        : Completer<List<Map<String, dynamic>>>();

    // Send the request
    await send(
      req,
      relayUrls: relayUrls,
      queryCompleter: completer,
      isStreaming: source.stream,
    );

    // Return nothing for background queries
    if (source.background) {
      return [];
    }

    // Wait for results
    List<Map<String, dynamic>> events;
    try {
      events = await completer!.future;
    } finally {
      // Close subscription unless explicitly streaming
      if (!source.stream) {
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

    final normalizedRelays = relayUrls.map(normalizeRelayUrl).toSet();

    final originalFilters = req
        .toMaps()
        .map((filter) => Map<String, dynamic>.from(filter))
        .toList();

    // Create subscription buffer with original filters
    final buffer = SubscriptionBuffer(
      subscriptionId: req.subscriptionId,
      targetRelays: normalizedRelays,
      isStreaming: isStreaming,
      batchWindow: config.streamingBufferWindow,
      onFlush: (events, relaysForIds) =>
          _handleEventBatch(req, events, relaysForIds),
      onFirstFlushTimeout: _handleEoseFirstFlushTimeout,
      onFinalTimeout: _handleEoseFinalTimeout,
      filters: originalFilters
          .map((filter) => Map<String, dynamic>.from(filter))
          .toList(),
    );

    buffer.queryCompleter = queryCompleter;
    _subscriptions[req.subscriptionId] = buffer;

    // Set up final EOSE timeout (removes stuck relays)
    buffer.eoseFinalTimeoutTimer = Timer(
      config.responseTimeout,
      () => _handleEoseFinalTimeout(req.subscriptionId),
    );

    // Subscribe to all relays
    final futures = <Future>[];
    for (final url in normalizedRelays) {
      final agent = _getOrCreateAgent(url);

      final filters = originalFilters
          .map((filter) => Map<String, dynamic>.from(filter))
          .toList();
      futures.add(agent.subscribe(req.subscriptionId, filters));
    }

    await Future.wait(futures);

    // Emit state
    _emitState();
  }

  /// Unsubscribe from subscription
  void unsubscribe(Request req) {
    final subscriptionId = req.subscriptionId;
    final buffer = _subscriptions[subscriptionId];

    if (buffer == null) {
      return;
    }

    // Unsubscribe from all target relays
    for (final url in buffer.targetRelays) {
      final agent = _agents[url];
      agent?.unsubscribe(subscriptionId);
    }

    // Clean up buffer
    buffer.dispose();
    _subscriptions.remove(subscriptionId);

    // Clean up idle agents (no active subscriptions)
    _cleanupIdleAgents();

    // Emit state
    _emitState();
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

    final response = PublishRelayResponse();

    // Publish to all relays
    final futures = <Future>[];
    for (final url in relayUrls) {
      final agent = _getOrCreateAgent(url);

      for (final event in events) {
        final eventId = event['id'] as String?;
        if (eventId == null) continue;

        final future = agent
            .publish(event)
            .then((result) {
              response.wrapped.addEvent(
                eventId,
                relayUrl: url,
                accepted: result.accepted,
              );
            })
            .catchError((error) {
              response.wrapped.addEvent(
                eventId,
                relayUrl: url,
                accepted: false,
              );
            });

        futures.add(future);
      }
    }

    await Future.wait(futures);

    return response;
  }

  /// Perform health check (called by main isolate heartbeat)
  /// Checks all agents and triggers reconnection if needed
  Future<void> performHealthCheck({bool force = false}) async {
    if (_disposed) return;

    // Check all agents and reconnect if needed
    final futures = _agents.values.map(
      (agent) => agent.checkAndReconnect(force: force),
    );
    await Future.wait(futures);

    // Emit updated state
    _emitState();
  }

  /// Get or create relay agent
  RelayAgent _getOrCreateAgent(String url) {
    return _agents.putIfAbsent(url, () {
      debugNotifier?.emit(DebugMessage('[pool] Creating agent for $url'));

      return RelayAgent(
        url: url,
        onStateChange: _handleAgentStateChange,
        onEvent: _handleEvent,
        onEose: _handleEose,
        onPublishResponse: _handlePublishResponse,
        connectionTimeout: config.responseTimeout,
      );
    });
  }

  /// Handle agent state change
  void _handleAgentStateChange(RelayAgentState state) {
    // Log important connection state changes
    switch (state.phase) {
      case ConnectionPhase.connected:
        // Only log reconnections, not initial connections
        if (state.reconnectAttempts > 0) {
          debugNotifier?.emit(
            DebugMessage(
              '[pool] Relay ${state.url} reconnected after ${state.reconnectAttempts} attempt(s)',
            ),
          );
        }
        break;
      case ConnectionPhase.disconnected:
        final errorMsg = state.lastError != null ? ' (${state.lastError})' : '';
        debugNotifier?.emit(
          DebugMessage('[pool] Relay ${state.url} disconnected$errorMsg'),
        );
        break;
      case ConnectionPhase.connecting:
        // Don't log connecting state, too noisy
        break;
    }

    // Agent state changed, emit updated pool state
    _emitState();
  }

  /// Handle event from agent
  void _handleEvent(String relayUrl, String subId, Map<String, dynamic> event) {
    debugNotifier?.emit(
      DebugMessage('[pool] EVENT received from $relayUrl for $subId'),
    );

    final buffer = _subscriptions[subId];
    if (buffer == null) {
      debugNotifier?.emit(
        DebugMessage('[pool] No buffer found for subscription $subId'),
      );
      return;
    }

    final eventId = event['id'] as String?;
    if (eventId == null) {
      debugNotifier?.emit(DebugMessage('[pool] Event missing id field'));
      return;
    }

    // Add to buffer (deduplication happens here)
    buffer.addEvent(relayUrl, event);
    debugNotifier?.emit(
      DebugMessage('[pool] Event $eventId added to buffer for $subId'),
    );
  }

  /// Handle EOSE from agent
  void _handleEose(String relayUrl, String subId) {
    debugNotifier?.emit(
      DebugMessage('[pool] EOSE received from $relayUrl for $subId'),
    );

    final buffer = _subscriptions[subId];
    if (buffer == null) {
      return;
    }

    buffer.markEose(relayUrl);

    // If all EOSE received, cancel both timers
    if (buffer.allEoseReceived) {
      buffer.eoseFirstFlushTimer?.cancel();
      buffer.eoseFinalTimeoutTimer?.cancel();
      debugNotifier?.emit(DebugMessage('[pool] All EOSE received for $subId'));
    }
  }

  /// Handle publish response from agent
  void _handlePublishResponse(
    String relayUrl,
    String eventId,
    bool accepted,
    String? message,
  ) {
    // Only log failures
    if (!accepted) {
      debugNotifier?.emit(
        DebugMessage(
          '[pool] Publish failed from $relayUrl for $eventId${message != null ? ': $message' : ''}',
        ),
      );
    }
  }

  /// Handle event batch flush from buffer
  void _handleEventBatch(
    Request req,
    List<Map<String, dynamic>> events,
    Map<String, Set<String>> relaysForIds,
  ) {
    if (events.isEmpty) {
      debugNotifier?.emit(
        DebugMessage(
          '[pool] Batch flush called with 0 events for ${req.subscriptionId}',
        ),
      );
      return;
    }

    debugNotifier?.emit(
      DebugMessage(
        '[pool] Emitting ${events.length} events for ${req.subscriptionId}',
      ),
    );

    eventNotifier.emitEvents(
      req: req,
      events: events.toSet(),
      relaysForIds: relaysForIds,
    );
  }

  /// Handle first EOSE flush timeout (triggered when first relay sends EOSE)
  void _handleEoseFirstFlushTimeout(String subscriptionId) {
    final buffer = _subscriptions[subscriptionId];
    if (buffer == null) return;

    // Only proceed if at least one relay sent EOSE
    if (buffer.eoseReceived.isEmpty) return;

    // Set up the timer if not already set
    buffer.eoseFirstFlushTimer ??= Timer(config.eoseFirstFlushTimeout, () {
      final buf = _subscriptions[subscriptionId];
      if (buf == null || buf.allEoseReceived) return;

      debugNotifier?.emit(
        DebugMessage(
          '[pool] First flush timeout for $subscriptionId - flushing events from ${buf.eoseReceived.length}/${buf.targetRelays.length} relays',
        ),
      );

      // Flush events received so far
      buf.flush();

      _emitState();
    });
  }

  /// Handle final EOSE timeout (removes stuck relays)
  void _handleEoseFinalTimeout(String subscriptionId) {
    final buffer = _subscriptions[subscriptionId];
    if (buffer == null) return;

    // Find relays that didn't send EOSE
    final slowRelays = buffer.targetRelays
        .where((url) => !buffer.eoseReceived.contains(url))
        .toList();

    if (slowRelays.isNotEmpty) {
      debugNotifier?.emit(
        DebugMessage(
          '[pool] Final EOSE timeout for $subscriptionId - closing slow relays: ${slowRelays.join(", ")}',
        ),
      );

      // Unsubscribe from slow/stuck relays
      for (final url in slowRelays) {
        final agent = _agents[url];
        agent?.unsubscribe(subscriptionId);
      }

      // Remove slow relays from buffer's target relays
      buffer.targetRelays.removeAll(slowRelays);

      // If we removed all relays, cancel the subscription entirely
      if (buffer.targetRelays.isEmpty) {
        debugNotifier?.emit(
          DebugMessage(
            '[pool] All relays timed out for $subscriptionId - cancelling subscription',
          ),
        );
        buffer.dispose();
        _subscriptions.remove(subscriptionId);
        _emitState();
        return;
      }
    }

    // Flush whatever events we have from responsive relays
    buffer.flush();

    _emitState();
  }

  /// Clean up agents with no active subscriptions
  void _cleanupIdleAgents() {
    final agentsToRemove = <String>[];

    for (final entry in _agents.entries) {
      final url = entry.key;
      final agent = entry.value;

      // Check if any subscription targets this agent
      final hasActiveSubscriptions = _subscriptions.values.any(
        (buffer) => buffer.targetRelays.contains(url),
      );

      if (!hasActiveSubscriptions && agent.state.activeSubscriptions.isEmpty) {
        agent.dispose();
        agentsToRemove.add(url);
      }
    }

    for (final url in agentsToRemove) {
      _agents.remove(url);
    }
  }

  /// Emit current pool state
  void _emitState() {
    stateNotifier.update(_buildPoolState());
  }

  /// Build current pool state
  PoolState _buildPoolState() {
    // Build connection states from agents
    final connections = <String, RelayConnectionState>{};
    for (final entry in _agents.entries) {
      final url = entry.key;
      final agent = entry.value;
      final agentState = agent.state;

      // Map agent phase to pool connection phase
      final phase = _mapAgentPhaseToConnectionPhase(agentState);

      connections[url] = RelayConnectionState(
        url: url,
        phase: phase,
        phaseStartedAt: agentState.phaseStartedAt,
        reconnectAttempts: agentState.reconnectAttempts,
        lastMessageAt: agentState.lastActivityAt,
        lastError: agentState.lastError,
        activeSubscriptionIds: agentState.activeSubscriptions.keys.toSet(),
      );
    }

    // Build subscription states from buffers
    final subscriptions = <String, SubscriptionState>{};
    for (final entry in _subscriptions.entries) {
      final subId = entry.key;
      final buffer = entry.value;

      // Build relay status map with actual filters sent to each relay
      final relayStatus = <String, RelaySubscriptionStatus>{};
      for (final url in buffer.targetRelays) {
        final agent = _agents[url];
        final subscriptionInfo = agent?.state.activeSubscriptions[subId];

        relayStatus[url] = RelaySubscriptionStatus(
          phase: const SubscriptionActive(),
          eoseReceivedAt: buffer.eoseReceivedAt[url],
          reconnectionAttempts: 0,
          lastReconnectAt: null,
          filters:
              subscriptionInfo?.filters, // Actual filters sent to this relay
        );
      }

      subscriptions[subId] = SubscriptionState(
        subscriptionId: subId,
        targetRelays: buffer.targetRelays,
        isStreaming: buffer.isStreaming,
        relayStatus: relayStatus,
        phase: buffer.allEoseReceived
            ? SubscriptionPhase.streaming
            : SubscriptionPhase.eose,
        startedAt: buffer.startedAt,
        totalEventsReceived: buffer.totalEventsReceived,
        filters: buffer.filters, // Original unoptimized filters
      );
    }

    // Build health metrics
    final health = _buildHealthMetrics(connections, subscriptions);

    return PoolState(
      connections: connections,
      subscriptions: subscriptions,
      publishes: const {}, // Simplified - no tracking needed
      health: health,
      timestamp: DateTime.now(),
    );
  }

  /// Map agent connection phase to pool connection phase
  pool_phase.ConnectionPhase _mapAgentPhaseToConnectionPhase(
    RelayAgentState agentState,
  ) {
    switch (agentState.phase) {
      case ConnectionPhase.disconnected:
        final reason = _resolveDisconnectionReason(agentState);
        return pool_phase.Disconnected(
          reason,
          agentState.phaseStartedAt,
          reconnectAttempts: agentState.reconnectAttempts,
          nextReconnectAt: agentState.nextReconnectAt,
          lastError: agentState.lastError,
        );
      case ConnectionPhase.connecting:
        return pool_phase.Connecting(agentState.phaseStartedAt);
      case ConnectionPhase.connected:
        return pool_phase.Connected(
          agentState.phaseStartedAt,
          isReconnection: agentState.reconnectAttempts > 0,
        );
    }
  }

  pool_phase.DisconnectionReason _resolveDisconnectionReason(
    RelayAgentState agentState,
  ) {
    if (agentState.activeSubscriptions.isEmpty &&
        agentState.reconnectAttempts == 0) {
      return pool_phase.DisconnectionReason.intentional;
    }

    if (agentState.reconnectAttempts == 0 && agentState.lastError == null) {
      return pool_phase.DisconnectionReason.initial;
    }

    if (agentState.lastError != null &&
        agentState.lastError!.contains('timeout')) {
      return pool_phase.DisconnectionReason.timeout;
    }

    return pool_phase.DisconnectionReason.socketError;
  }

  /// Build health metrics
  HealthMetrics _buildHealthMetrics(
    Map<String, RelayConnectionState> connections,
    Map<String, SubscriptionState> subscriptions,
  ) {
    final connectedCount = connections.values
        .where((c) => c.phase is pool_phase.Connected)
        .length;
    final disconnectedCount = connections.values
        .where((c) => c.phase is pool_phase.Disconnected)
        .length;
    final connectingCount = connections.values
        .where((c) => c.phase is pool_phase.Connecting)
        .length;

    final fullyActive = subscriptions.values.where((s) {
      return s.relayStatus.values.every(
        (status) => status.eoseReceivedAt != null,
      );
    }).length;

    final partiallyActive = subscriptions.values.where((s) {
      final activeCount = s.relayStatus.values
          .where((status) => status.eoseReceivedAt != null)
          .length;
      return activeCount > 0 && activeCount < s.targetRelays.length;
    }).length;

    return HealthMetrics(
      totalConnections: connections.length,
      connectedCount: connectedCount,
      disconnectedCount: disconnectedCount,
      connectingCount: connectingCount,
      totalSubscriptions: subscriptions.length,
      fullyActiveSubscriptions: fullyActive,
      partiallyActiveSubscriptions: partiallyActive,
      failedSubscriptions: 0,
      lastHealthCheckAt: DateTime.now(),
    );
  }

  /// Dispose pool
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    // Dispose all buffers
    for (final buffer in _subscriptions.values) {
      buffer.dispose();
    }
    _subscriptions.clear();

    // Dispose all agents
    for (final agent in _agents.values) {
      agent.dispose();
    }
    _agents.clear();

    debugNotifier?.emit(DebugMessage('[pool] WebSocketPool disposed'));
  }
}
