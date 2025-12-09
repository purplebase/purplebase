import 'dart:async';

import 'package:models/models.dart';

import 'connection.dart';
import 'state.dart';
import 'subscription.dart';

/// Simplified WebSocket pool coordinator
/// Manages connections to relays and subscription lifecycle
class RelayPool {
  final StorageConfiguration config;
  final void Function(PoolState state) onStateChange;
  final void Function({
    required Request req,
    required List<Map<String, dynamic>> events,
    required Map<String, Set<String>> relaysForIds,
  })
  onEvents;

  // Connections (normalized URL -> connection)
  final Map<String, Connection> _connections = {};

  // Subscriptions (subscription ID -> subscription)
  final Map<String, Subscription> _subscriptions = {};

  // State tracking
  final Map<String, RelayState> _relayStates = {};
  final Map<String, RequestState> _requestStates = {};

  bool _disposed = false;

  RelayPool({
    required this.config,
    required this.onStateChange,
    required this.onEvents,
  });

  /// Query relays
  Future<List<Map<String, dynamic>>> query(
    Request req, {
    RemoteSource source = const RemoteSource(),
  }) async {
    // If stream is false and background is true, force background=false to prevent hangs
    if (!source.stream && source.background == true) {
      source = source.copyWith(background: false);
    }

    final relayUrls = config
        .getRelays(source: source)
        .map(_normalizeUrl)
        .toSet();

    if (relayUrls.isEmpty) return [];

    final completer = source.background
        ? null
        : Completer<List<Map<String, dynamic>>>();

    await _subscribe(
      req,
      relayUrls: relayUrls,
      queryCompleter: completer,
      isStreaming: source.stream,
    );

    if (source.background) return [];

    List<Map<String, dynamic>> events;
    try {
      events = await completer!.future;
    } finally {
      if (!source.stream) {
        unsubscribe(req);
      }
    }

    return events;
  }

  /// Subscribe to relays
  Future<void> _subscribe(
    Request req, {
    required Set<String> relayUrls,
    Completer<List<Map<String, dynamic>>>? queryCompleter,
    bool isStreaming = false,
  }) async {
    if (relayUrls.isEmpty) return;

    final filters = req
        .toMaps()
        .map((f) => Map<String, dynamic>.from(f))
        .toList();

    // Create subscription
    final subscription = Subscription(
      subscriptionId: req.subscriptionId,
      filters: filters,
      targetRelays: relayUrls,
      isStreaming: isStreaming,
      batchWindow: config.streamingBufferWindow,
      onFlush: (events, relaysForIds) =>
          _handleEventFlush(req, events, relaysForIds),
    );

    subscription.queryCompleter = queryCompleter;
    _subscriptions[req.subscriptionId] = subscription;

    // Set up EOSE timeout
    subscription.eoseTimeoutTimer = Timer(
      config.responseTimeout,
      () => _handleEoseTimeout(req.subscriptionId),
    );

    // Update request state
    _requestStates[req.subscriptionId] = RequestState(
      subscriptionId: req.subscriptionId,
      filters: filters,
      targetRelays: relayUrls,
      isStreaming: isStreaming,
      startedAt: DateTime.now(),
    );

    // Subscribe on all relay connections
    final futures = <Future>[];
    for (final url in relayUrls) {
      final conn = _getOrCreateConnection(url);
      futures.add(conn.subscribe(req.subscriptionId, filters));
    }

    await Future.wait(futures);
    _emitState(
      'Subscribed ${req.subscriptionId} to ${relayUrls.length} relays',
    );
  }

  /// Unsubscribe from a request
  void unsubscribe(Request req) {
    final subId = req.subscriptionId;
    final subscription = _subscriptions[subId];
    if (subscription == null) return;

    // Unsubscribe from all connections
    for (final url in subscription.targetRelays) {
      _connections[url]?.unsubscribe(subId);
    }

    subscription.dispose();
    _subscriptions.remove(subId);
    _requestStates.remove(subId);

    _cleanupIdleConnections();
    _emitState('Unsubscribed $subId');
  }

  /// Publish events to relays
  Future<PublishRelayResponse> publish(
    List<Map<String, dynamic>> events, {
    RemoteSource source = const RemoteSource(),
  }) async {
    if (events.isEmpty) return PublishRelayResponse();

    final relayUrls = config
        .getRelays(source: source)
        .map(_normalizeUrl)
        .toSet();

    if (relayUrls.isEmpty) return PublishRelayResponse();

    final response = PublishRelayResponse();
    final futures = <Future>[];

    for (final url in relayUrls) {
      final conn = _getOrCreateConnection(url);

      for (final event in events) {
        final eventId = event['id'] as String?;
        if (eventId == null) continue;

        final future = conn
            .publish(event)
            .then((result) {
              response.wrapped.addEvent(
                eventId,
                relayUrl: url,
                accepted: result.accepted,
              );
            })
            .catchError((_) {
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

  /// Perform health check on all connections
  Future<void> performHealthCheck({bool force = false}) async {
    if (_disposed) return;

    final futures = _connections.values.map(
      (conn) => conn.checkHealth(force: force),
    );
    await Future.wait(futures);
  }

  /// Get or create a connection
  Connection _getOrCreateConnection(String url) {
    return _connections.putIfAbsent(url, () {
      _relayStates[url] = RelayState(
        url: url,
        status: ConnectionStatus.disconnected,
        statusChangedAt: DateTime.now(),
      );

      return Connection(
        url: url,
        connectionTimeout: config.responseTimeout,
        onStatusChange: _handleConnectionStatusChange,
        onEvent: _handleEvent,
        onEose: _handleEose,
        onPublishResponse: _handlePublishResponse,
      );
    });
  }

  void _handleConnectionStatusChange(
    String url,
    ConnectionStatus status, {
    String? error,
    int? attempts,
  }) {
    final prevState = _relayStates[url];
    _relayStates[url] = RelayState(
      url: url,
      status: status,
      reconnectAttempts: attempts ?? prevState?.reconnectAttempts ?? 0,
      error: error,
      lastActivityAt: DateTime.now(),
      statusChangedAt: DateTime.now(),
    );

    final statusStr = switch (status) {
      ConnectionStatus.connected => 'Connected to $url',
      ConnectionStatus.connecting =>
        'Connecting to $url${attempts != null && attempts > 0 ? ' (attempt $attempts)' : ''}',
      ConnectionStatus.disconnected =>
        'Disconnected from $url${error != null ? ': $error' : ''}',
    };

    _emitState(statusStr);
  }

  void _handleEvent(String relayUrl, String subId, Map<String, dynamic> event) {
    final subscription = _subscriptions[subId];
    if (subscription == null) return;

    subscription.addEvent(relayUrl, event);

    // Update request state
    final reqState = _requestStates[subId];
    if (reqState != null) {
      _requestStates[subId] = reqState.copyWith(
        eventCount: subscription.eventCount,
      );
    }
  }

  void _handleEose(String relayUrl, String subId) {
    final subscription = _subscriptions[subId];
    if (subscription == null) return;

    subscription.markEose(relayUrl);

    // Update request state
    final reqState = _requestStates[subId];
    if (reqState != null) {
      _requestStates[subId] = reqState.copyWith(
        eoseReceived: Set.from(subscription.eoseReceived),
      );
      _emitState(
        'EOSE from $relayUrl for $subId (${subscription.eoseReceived.length}/${subscription.targetRelays.length})',
      );
    }

    // If all EOSE received, cancel timeout
    if (subscription.allEoseReceived) {
      subscription.eoseTimeoutTimer?.cancel();
    }
  }

  void _handlePublishResponse(
    String relayUrl,
    String eventId,
    bool accepted,
    String? message,
  ) {
    if (!accepted) {
      _emitState(
        'Publish rejected by $relayUrl: $eventId${message != null ? ' ($message)' : ''}',
      );
    }
  }

  void _handleEventFlush(
    Request req,
    List<Map<String, dynamic>> events,
    Map<String, Set<String>> relaysForIds,
  ) {
    if (events.isEmpty) return;

    onEvents(req: req, events: events, relaysForIds: relaysForIds);
  }

  void _handleEoseTimeout(String subId) {
    final subscription = _subscriptions[subId];
    if (subscription == null) return;

    // Find relays that didn't send EOSE
    final slowRelays = subscription.targetRelays
        .where((url) => !subscription.eoseReceived.contains(url))
        .toList();

    if (slowRelays.isNotEmpty) {
      _emitState(
        'EOSE timeout for $subId - slow relays: ${slowRelays.join(", ")}',
      );

      // Unsubscribe from slow relays
      for (final url in slowRelays) {
        _connections[url]?.unsubscribe(subId);
      }
    }

    // Flush whatever we have
    subscription.flush();
  }

  void _cleanupIdleConnections() {
    final toRemove = <String>[];

    for (final entry in _connections.entries) {
      final url = entry.key;
      final conn = entry.value;

      // Check if any subscription targets this connection
      final hasActiveSubscriptions = _subscriptions.values.any(
        (sub) => sub.targetRelays.contains(url),
      );

      if (!hasActiveSubscriptions && conn.activeSubscriptionIds.isEmpty) {
        conn.dispose();
        toRemove.add(url);
      }
    }

    for (final url in toRemove) {
      _connections.remove(url);
      _relayStates.remove(url);
    }
  }

  void _emitState(String change) {
    onStateChange(
      PoolState(
        relays: Map.from(_relayStates),
        requests: Map.from(_requestStates),
        timestamp: DateTime.now(),
        lastChange: change,
      ),
    );
  }

  String _normalizeUrl(String url) {
    if (url.isEmpty) return url;
    var normalized = url;
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized.toLowerCase();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final sub in _subscriptions.values) {
      sub.dispose();
    }
    _subscriptions.clear();

    for (final conn in _connections.values) {
      conn.dispose();
    }
    _connections.clear();

    _relayStates.clear();
    _requestStates.clear();
  }
}

/// Response wrapper for publish operations
class PublishRelayResponse {
  final wrapped = PublishResponse();
}
