import 'dart:async';
import 'dart:convert';

import 'package:models/models.dart';

import 'connection.dart';
import 'state.dart';

/// Internal managed socket with reconnection state
class _ManagedSocket {
  final String url;
  final RelaySocket socket;
  Timer? reconnectTimer;

  /// Which subscriptions use this socket
  final Set<String> subscriptionIds = {};

  /// Reconnection attempts for this relay (shared across all subscriptions)
  int reconnectAttempts = 0;

  /// Last error message for this relay
  String? lastError;

  /// Pending ping completer for zombie detection
  Completer<void>? pingCompleter;
  static const pingSubId = '__ping__';

  _ManagedSocket({required this.url, required this.socket});

  void dispose() {
    reconnectTimer?.cancel();
    pingCompleter?.complete(); // Complete any pending ping
    socket.dispose();
  }
}

/// Pending publish operation
class _PendingPublish {
  final String eventId;
  final String relayUrl;
  final Completer<PublishResult> completer;
  final Timer timeoutTimer;

  _PendingPublish({
    required this.eventId,
    required this.relayUrl,
    required this.completer,
    required this.timeoutTimer,
  });

  void dispose() {
    timeoutTimer.cancel();
    if (!completer.isCompleted) {
      completer.complete(
        PublishResult(
          eventId: eventId,
          relayUrl: relayUrl,
          accepted: false,
          message: 'Cancelled',
        ),
      );
    }
  }
}

/// WebSocket pool - single source of truth for all state
class RelayPool {
  final StorageConfiguration config;
  final void Function(PoolState state) onStateChange;
  final void Function({
    required Request req,
    required List<Map<String, dynamic>> events,
    required Map<String, Set<String>> relaysForIds,
  })
  onEvents;

  // === THE STATE (single source of truth) ===
  final Map<String, Subscription> _subscriptions = {};
  final List<LogEntry> _logs = [];

  // === INTERNAL (not in state) ===
  final Map<String, _ManagedSocket> _sockets = {};
  final Map<String, _PendingPublish> _pendingPublishes = {};

  // Event buffering for deduplication
  final Map<String, _EventBuffer> _eventBuffers = {};

  bool _disposed = false;

  RelayPool({
    required this.config,
    required this.onStateChange,
    required this.onEvents,
  });

  // ============================================================
  // PUBLIC API
  // ============================================================

  /// Query relays
  ///
  /// For `stream=false`: blocks until all EOSEs, returns events, auto-unsubscribes.
  /// For `stream=true`: returns [] immediately, events flow via onEvents callback.
  Future<List<Map<String, dynamic>>> query(
    Request req, {
    RemoteSource source = const RemoteSource(),
  }) async {
    if (source.relays is! Iterable<String>) return [];
    final relayUrls = (source.relays as Iterable<String>).toSet();
    if (relayUrls.isEmpty) return [];

    if (source.stream) {
      // Streaming: no completer, events via callback, stays open until cancel
      _createSubscription(
        req,
        relayUrls: relayUrls,
        stream: true,
        queryCompleter: null,
      );
      return [];
    }

    // One-shot query: create completer to get results
    final completer = Completer<List<Map<String, dynamic>>>();

    _createSubscription(
      req,
      relayUrls: relayUrls,
      stream: false,
      queryCompleter: completer,
    );

    // Pool auto-unsubscribes after all EOSEs for stream=false
    return completer.future;
  }

  /// Unsubscribe from a request
  void unsubscribe(Request req) {
    final subId = req.subscriptionId;
    final sub = _subscriptions[subId];
    if (sub == null) return;

    // Clean up for all relays (connected or not)
    for (final url in sub.relays.keys) {
      final managed = _sockets[url];
      if (managed != null) {
        // Send CLOSE if connected
        if (managed.socket.isConnected) {
          managed.socket.sendClose(subId);
        }

        // ALWAYS remove from subscriptionIds, regardless of connection state
        managed.subscriptionIds.remove(subId);

        // Cancel reconnect timer if no more subscriptions for this socket
        if (managed.subscriptionIds.isEmpty) {
          managed.reconnectTimer?.cancel();
        }
      }
    }

    // Clean up event buffer
    _eventBuffers[subId]?.dispose();
    _eventBuffers.remove(subId);

    // Remove subscription
    _subscriptions.remove(subId);

    // Log completion
    _log(LogLevel.info, '$subId completed', subscriptionId: subId);

    // Clean up idle sockets
    _cleanupIdleSockets();

    _emit();
  }

  /// Publish events to relays
  Future<PublishRelayResponse> publish(
    List<Map<String, dynamic>> events, {
    RemoteSource source = const RemoteSource(),
  }) async {
    if (events.isEmpty) return PublishRelayResponse();

    source.relays as Iterable;
    if (source.relays.isEmpty) return PublishRelayResponse();

    final response = PublishRelayResponse();
    final futures = <Future<PublishResult>>[];

    for (final url in source.relays) {
      for (final event in events) {
        final eventId = event['id'] as String?;
        if (eventId == null) continue;

        futures.add(_publishToRelay(url, event, eventId));
      }
    }

    final results = await Future.wait(futures);
    for (final result in results) {
      response.wrapped.addEvent(
        result.eventId,
        relayUrl: result.relayUrl,
        accepted: result.accepted,
      );
    }

    // Clean up sockets that have no active subscriptions
    _cleanupIdleSockets();

    return response;
  }

  /// Perform health check - called by heartbeat from main isolate
  Future<void> performHealthCheck({bool force = false}) async {
    if (_disposed) return;

    final now = DateTime.now();

    for (final entry in _subscriptions.entries) {
      final subId = entry.key;
      final sub = entry.value;

      for (final relayEntry in sub.relays.entries) {
        final url = relayEntry.key;
        final relayState = relayEntry.value;

        switch (relayState.phase) {
          case RelaySubPhase.loading:
          case RelaySubPhase.streaming:
            // Check if we should ping for zombie detection
            final socketActivity = _sockets[url]?.socket.lastActivityAt;
            final lastActivity = relayState.lastEventAt ?? socketActivity;
            if (lastActivity != null) {
              final idle = now.difference(lastActivity);
              if (idle > PoolConstants.pingIdleThreshold) {
                await _pingRelay(subId, url);
              }
            }

          case RelaySubPhase.connecting:
            // Already connecting, do nothing
            break;

          case RelaySubPhase.waiting:
            // Check if backoff timer should have fired (backup check)
            final managed = _sockets[url];
            if (managed?.reconnectTimer?.isActive != true) {
              // Timer not active, try to reconnect
              _connectRelay(subId, url);
            }

          case RelaySubPhase.disconnected:
            // Should be reconnecting, trigger connection
            _connectRelay(subId, url);

          case RelaySubPhase.failed:
            // Do nothing - user must cancel and resubscribe
            break;
        }
      }
    }
  }

  /// Force immediate reconnection - called on app resume
  /// Restarts all non-connected relays including failed ones
  void connect() {
    if (_disposed) return;

    for (final entry in _subscriptions.entries) {
      final subId = entry.key;
      final sub = entry.value;

      for (final relayEntry in sub.relays.entries) {
        final url = relayEntry.key;
        final relayState = relayEntry.value;

        // Restart disconnected, waiting, or failed relays
        if (relayState.phase == RelaySubPhase.disconnected ||
            relayState.phase == RelaySubPhase.waiting ||
            relayState.phase == RelaySubPhase.failed) {
          // Cancel any backoff timer and reset relay-level attempts
          final managed = _sockets[url];
          if (managed != null) {
            managed.reconnectTimer?.cancel();
            managed.reconnectAttempts = 0;
            managed.lastError = null;
          }

          // Reset attempts and connect immediately
          _updateRelayState(
            subId,
            url,
            relayState.copyWith(
              phase: RelaySubPhase.disconnected,
              reconnectAttempts: 0,
              clearError: true,
            ),
          );
          _connectRelay(subId, url);
        }
      }
    }
  }

  /// Disconnect all relays and cancel all subscriptions - called on app pause
  void disconnect() {
    if (_disposed) return;

    // Cancel all backoff timers
    for (final managed in _sockets.values) {
      managed.reconnectTimer?.cancel();
    }

    // Send CLOSE for all subscriptions and disconnect sockets
    for (final entry in _subscriptions.entries) {
      final subId = entry.key;
      final sub = entry.value;

      for (final url in sub.relays.keys) {
        final managed = _sockets[url];
        if (managed?.socket.isConnected == true) {
          managed!.socket.sendClose(subId);
        }

        // Update relay state to disconnected
        final relayState = sub.relays[url];
        if (relayState != null) {
          _updateRelayState(
            subId,
            url,
            relayState.copyWith(
              phase: RelaySubPhase.disconnected,
              clearStreamingSince: true,
            ),
            emit: false,
          );
        }
      }
    }

    // Disconnect all sockets
    for (final managed in _sockets.values) {
      managed.socket.disconnect();
    }

    _emit();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;

    // Clean up event buffers
    for (final buffer in _eventBuffers.values) {
      buffer.dispose();
    }
    _eventBuffers.clear();

    // Clean up pending publishes
    for (final pending in _pendingPublishes.values) {
      pending.dispose();
    }
    _pendingPublishes.clear();

    // Clean up sockets
    for (final managed in _sockets.values) {
      managed.dispose();
    }
    _sockets.clear();

    _subscriptions.clear();
  }

  // ============================================================
  // SUBSCRIPTION MANAGEMENT
  // ============================================================

  void _createSubscription(
    Request req, {
    required Set<String> relayUrls,
    required bool stream,
    Completer<List<Map<String, dynamic>>>? queryCompleter,
  }) {
    final subId = req.subscriptionId;

    // Create relay states
    final relays = <String, RelaySubState>{};
    for (final url in relayUrls) {
      relays[url] = const RelaySubState(phase: RelaySubPhase.disconnected);
    }

    // Create subscription
    final sub = Subscription(
      id: subId,
      request: req,
      stream: stream,
      startedAt: DateTime.now(),
      relays: relays,
    );
    _subscriptions[subId] = sub;

    // Create event buffer
    _eventBuffers[subId] = _EventBuffer(
      subscriptionId: subId,
      batchWindow: config.streamingBufferWindow,
      totalRelayCount: relayUrls.length,
      queryCompleter: queryCompleter,
      onFlush: (events, relaysForIds) {
        if (events.isNotEmpty) {
          onEvents(req: req, events: events, relaysForIds: relaysForIds);
        }
      },
    );

    // Set up EOSE timeout
    _eventBuffers[subId]!.eoseTimeoutTimer = Timer(
      config.responseTimeout,
      () => _handleEoseTimeout(subId),
    );

    // Start connecting to all relays
    for (final url in relayUrls) {
      _connectRelay(subId, url);
    }

    _emit();
  }

  // ============================================================
  // CONNECTION MANAGEMENT
  // ============================================================

  void _connectRelay(String subId, String url) {
    final sub = _subscriptions[subId];
    if (sub == null) return;

    final relayState = sub.relays[url];
    if (relayState == null) return;

    // Don't connect if already connecting/connected or failed
    if (relayState.phase == RelaySubPhase.connecting ||
        relayState.phase == RelaySubPhase.loading ||
        relayState.phase == RelaySubPhase.streaming ||
        relayState.phase == RelaySubPhase.failed) {
      return;
    }

    // Update phase to connecting
    _updateRelayState(
      subId,
      url,
      relayState.copyWith(phase: RelaySubPhase.connecting),
    );

    // Get or create socket
    final managed = _getOrCreateSocket(url);
    managed.subscriptionIds.add(subId);

    // Connect if not already connected
    if (!managed.socket.isConnected) {
      managed.socket
          .connect()
          .then((_) {
            _onSocketConnected(url);
          })
          .catchError((e) {
            _onSocketError(url, e.toString());
          });
    } else {
      // Already connected, send subscription
      _sendSubscription(subId, url);
    }
  }

  _ManagedSocket _getOrCreateSocket(String url) {
    return _sockets.putIfAbsent(url, () {
      final socket = RelaySocket(
        url: url,
        onMessage: (msg) => _handleMessage(url, msg),
        onDisconnect: (err) => _onSocketDisconnected(url, err),
      );
      return _ManagedSocket(url: url, socket: socket);
    });
  }

  void _onSocketConnected(String url) {
    // Send subscriptions to this relay
    for (final entry in _subscriptions.entries) {
      final subId = entry.key;
      final sub = entry.value;

      if (sub.relays.containsKey(url)) {
        _sendSubscription(subId, url);
      }
    }
  }

  void _sendSubscription(String subId, String url) {
    final sub = _subscriptions[subId];
    if (sub == null) return;

    final managed = _sockets[url];
    if (managed == null || !managed.socket.isConnected) return;

    final relayState = sub.relays[url];
    if (relayState == null) return;

    // Update to loading phase
    _updateRelayState(
      subId,
      url,
      relayState.copyWith(phase: RelaySubPhase.loading),
    );

    // Build filters with 'since' if we have a lastEventAt (for reconnection)
    var filters = sub.request
        .toMaps()
        .map((f) => Map<String, dynamic>.from(f))
        .toList();

    if (relayState.lastEventAt != null && sub.stream) {
      // Subtract 1 second to ensure we don't miss events at the boundary
      final since =
          (relayState.lastEventAt!.millisecondsSinceEpoch ~/ 1000) - 1;
      filters = filters.map((f) {
        final newFilter = Map<String, dynamic>.from(f);
        newFilter['since'] = since;
        return newFilter;
      }).toList();
    }

    managed.socket.sendReq(subId, filters);
  }

  void _onSocketDisconnected(String url, String? error) {
    final managed = _sockets[url];
    if (managed == null) return;

    // Increment attempts ONCE at relay level
    managed.reconnectAttempts++;
    managed.lastError = error;

    final shouldFail = managed.reconnectAttempts >= PoolConstants.maxRetries;
    final newPhase = shouldFail ? RelaySubPhase.failed : RelaySubPhase.waiting;

    // Update ALL subscriptions to same phase
    for (final subId in managed.subscriptionIds.toList()) {
      final sub = _subscriptions[subId];
      if (sub == null) continue;

      final relayState = sub.relays[url];
      if (relayState == null) continue;

      // Don't update if already failed
      if (relayState.phase == RelaySubPhase.failed) continue;

      _updateRelayState(
        subId,
        url,
        relayState.copyWith(
          phase: newPhase,
          reconnectAttempts: managed.reconnectAttempts,
          lastError: error ?? (shouldFail ? 'Max retries exceeded' : null),
          clearStreamingSince: true,
        ),
        emit: false, // Batch - emit once at end
      );
    }

    if (shouldFail) {
      _log(
        LogLevel.error,
        'Relay failed after ${managed.reconnectAttempts} attempts',
        relayUrl: url,
      );
    } else {
      // Schedule ONE reconnect for the relay
      _scheduleReconnect(url);
    }

    _emit();
  }

  void _onSocketError(String url, String error) {
    _log(
      LogLevel.error,
      'Socket error',
      relayUrl: url,
      exception: Exception(error),
    );
    _onSocketDisconnected(url, error);
  }

  void _scheduleReconnect(String url) {
    final managed = _sockets[url];
    if (managed == null) return;

    // Cancel existing timer
    managed.reconnectTimer?.cancel();

    // Get backoff delay from schedule
    final delay = PoolConstants.getBackoffDelay(managed.reconnectAttempts);
    if (delay == null) return; // Should not happen, but safety check

    managed.reconnectTimer = Timer(delay, () {
      if (!_disposed) {
        _reconnectRelay(url);
      }
    });
  }

  /// Reconnect all subscriptions for a relay
  void _reconnectRelay(String url) {
    final managed = _sockets[url];
    if (managed == null) return;

    // Update all subscriptions to connecting phase
    for (final subId in managed.subscriptionIds) {
      final sub = _subscriptions[subId];
      if (sub == null) continue;

      final relayState = sub.relays[url];
      if (relayState == null) continue;
      if (relayState.phase == RelaySubPhase.failed) continue;

      _updateRelayState(
        subId,
        url,
        relayState.copyWith(phase: RelaySubPhase.connecting),
        emit: false,
      );
    }

    _emit();

    // Connect socket once - _onSocketConnected will send all REQs
    managed.socket
        .connect()
        .then((_) => _onSocketConnected(url))
        .catchError((e) => _onSocketError(url, e.toString()));
  }

  // ============================================================
  // MESSAGE HANDLING
  // ============================================================

  void _handleMessage(String url, String message) {
    try {
      final data = jsonDecode(message) as List<dynamic>;
      final messageType = data[0] as String;

      switch (messageType) {
        case 'EVENT':
          if (data.length >= 3) {
            final subId = data[1] as String;
            final event = data[2] as Map<String, dynamic>;
            _handleEvent(url, subId, event);
          }

        case 'EOSE':
          if (data.length >= 2) {
            final subId = data[1] as String;
            _handleEose(url, subId);
          }

        case 'OK':
          if (data.length >= 3) {
            final eventId = data[1] as String;
            final accepted = data[2] as bool;
            final msg = data.length > 3 ? data[3] as String? : null;
            _handleOk(url, eventId, accepted, msg);
          }

        case 'CLOSED':
          if (data.length >= 2) {
            final subId = data[1] as String;
            _handleClosed(url, subId);
          }

        case 'NOTICE':
          // Ignore notices for now
          break;
      }
    } catch (e) {
      _log(
        LogLevel.warning,
        'Failed to parse message',
        relayUrl: url,
        exception: Exception(e.toString()),
      );
    }
  }

  void _handleEvent(String url, String subId, Map<String, dynamic> event) {
    // Check for ping response
    if (subId == _ManagedSocket.pingSubId) {
      return; // Ping events are ignored, we only care about EOSE
    }

    final sub = _subscriptions[subId];
    if (sub == null) return;

    final buffer = _eventBuffers[subId];
    if (buffer == null) return;

    // Update lastEventAt for this relay
    final relayState = sub.relays[url];
    if (relayState != null) {
      _updateRelayState(
        subId,
        url,
        relayState.copyWith(lastEventAt: DateTime.now()),
        emit: false, // Don't emit for every event
      );
    }

    // Add to buffer (handles deduplication)
    buffer.addEvent(url, event);
  }

  void _handleEose(String url, String subId) {
    // Check for ping response
    if (subId == _ManagedSocket.pingSubId) {
      final managed = _sockets[url];
      managed?.pingCompleter?.complete();
      return;
    }

    final sub = _subscriptions[subId];
    if (sub == null) return;

    final buffer = _eventBuffers[subId];
    if (buffer == null) return;

    final relayState = sub.relays[url];
    if (relayState == null) return;

    // Reset relay-level attempts on success
    final managed = _sockets[url];
    if (managed != null) {
      managed.reconnectAttempts = 0;
      managed.lastError = null;
    }

    // Update to streaming phase - clear error and reset attempts on success
    _updateRelayState(
      subId,
      url,
      relayState.copyWith(
        phase: RelaySubPhase.streaming,
        streamingSince: DateTime.now(),
        reconnectAttempts: 0,
        clearError: true,
      ),
    );

    // Mark EOSE in buffer (triggers flush based on queryCompleter presence)
    buffer.markEose(url);

    // Check if all relays have sent EOSE
    if (buffer.allEoseReceived) {
      buffer.eoseTimeoutTimer?.cancel();

      // Auto-unsubscribe for one-shot subscriptions (stream=false)
      if (!sub.stream) {
        unsubscribe(sub.request);
      }
    }
  }

  void _handleOk(String url, String eventId, bool accepted, String? message) {
    final key = '$url:$eventId';
    final pending = _pendingPublishes.remove(key);
    if (pending == null) return;

    pending.timeoutTimer.cancel();
    if (!pending.completer.isCompleted) {
      pending.completer.complete(
        PublishResult(
          eventId: eventId,
          relayUrl: url,
          accepted: accepted,
          message: message,
        ),
      );
    }

    if (!accepted) {
      _log(LogLevel.warning, 'Publish rejected: $message', relayUrl: url);
    }
  }

  void _handleClosed(String url, String subId) {
    // Handle ping subscription close - relay is alive, just rejected the ping
    if (subId == _ManagedSocket.pingSubId) {
      final managed = _sockets[url];
      if (managed?.pingCompleter != null &&
          !managed!.pingCompleter!.isCompleted) {
        managed.pingCompleter!.complete(); // Connection is alive!
      }
      return;
    }

    final sub = _subscriptions[subId];
    if (sub == null) return;

    // Relay closed our subscription - try to resend if still active
    if (sub.relays.containsKey(url)) {
      _sendSubscription(subId, url);
    }
  }

  void _handleEoseTimeout(String subId) {
    final sub = _subscriptions[subId];
    if (sub == null) return;

    final buffer = _eventBuffers[subId];
    if (buffer == null) return;

    // Find relays that connected but didn't send EOSE
    final slowRelays = sub.relays.entries
        .where((e) => e.value.phase == RelaySubPhase.loading)
        .map((e) => e.key)
        .toList();

    if (slowRelays.isNotEmpty) {
      _log(
        LogLevel.warning,
        'EOSE timeout - slow relays: ${slowRelays.join(", ")}',
        subscriptionId: subId,
      );
    }

    // Flush whatever we have
    buffer.flush();

    // Auto-unsubscribe for one-shot subscriptions after timeout
    // This prevents resource leaks when not all relays respond
    if (!sub.stream) {
      unsubscribe(sub.request);
    }
  }

  // ============================================================
  // PUBLISH
  // ============================================================

  Future<PublishResult> _publishToRelay(
    String url,
    Map<String, dynamic> event,
    String eventId,
  ) async {
    final managed = _getOrCreateSocket(url);

    // Connect if not connected
    if (!managed.socket.isConnected) {
      try {
        await managed.socket.connect();
      } catch (e) {
        return PublishResult(
          eventId: eventId,
          relayUrl: url,
          accepted: false,
          message: 'Connection failed: $e',
        );
      }
    }

    if (!managed.socket.isConnected) {
      return PublishResult(
        eventId: eventId,
        relayUrl: url,
        accepted: false,
        message: 'Not connected',
      );
    }

    final completer = Completer<PublishResult>();
    final key = '$url:$eventId';

    // Set up timeout
    final timeoutTimer = Timer(config.responseTimeout, () {
      final pending = _pendingPublishes.remove(key);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.complete(
          PublishResult(
            eventId: eventId,
            relayUrl: url,
            accepted: false,
            message: 'Timeout',
          ),
        );
      }
    });

    _pendingPublishes[key] = _PendingPublish(
      eventId: eventId,
      relayUrl: url,
      completer: completer,
      timeoutTimer: timeoutTimer,
    );

    managed.socket.sendEvent(event);

    return completer.future;
  }

  // ============================================================
  // PING / ZOMBIE DETECTION
  // ============================================================

  Future<void> _pingRelay(String subId, String url) async {
    final managed = _sockets[url];
    if (managed == null || !managed.socket.isConnected) return;

    // Already pinging
    if (managed.pingCompleter != null && !managed.pingCompleter!.isCompleted) {
      return;
    }

    managed.pingCompleter = Completer<void>();

    final sent = managed.socket.sendPing(_ManagedSocket.pingSubId);
    if (!sent) {
      // Failed to send ping - socket is broken
      _log(
        LogLevel.warning,
        'Failed to send ping (socket broken)',
        subscriptionId: subId,
        relayUrl: url,
      );
      managed.pingCompleter = null;
      managed.socket.disconnect();
      _onSocketDisconnected(url, 'Send failed');
      return;
    }

    var timedOut = false;
    try {
      await managed.pingCompleter!.future.timeout(
        PoolConstants.relayTimeout,
        onTimeout: () {
          timedOut = true;
          // Zombie detected
          _log(
            LogLevel.warning,
            'Zombie connection detected (ping timeout)',
            subscriptionId: subId,
            relayUrl: url,
          );
          managed.socket.disconnect();
          _onSocketDisconnected(url, 'Ping timeout');
        },
      );
    } finally {
      // Clean up ping subscription
      if (!timedOut && managed.socket.isConnected) {
        managed.socket.sendClose(_ManagedSocket.pingSubId);
      }
      managed.pingCompleter = null;
    }
  }

  // ============================================================
  // STATE MANAGEMENT
  // ============================================================

  void _updateRelayState(
    String subId,
    String url,
    RelaySubState newState, {
    bool emit = true,
  }) {
    final sub = _subscriptions[subId];
    if (sub == null) return;

    final oldState = sub.relays[url];
    final phaseChanged = oldState?.phase != newState.phase;

    _subscriptions[subId] = sub.updateRelay(url, newState);

    // Only emit on phase changes
    if (emit && phaseChanged) {
      _emit();
    }
  }

  void _cleanupIdleSockets() {
    final toRemove = <String>[];

    for (final entry in _sockets.entries) {
      final url = entry.key;
      final managed = entry.value;

      // Check if any subscription uses this socket
      final hasActiveSubscriptions = _subscriptions.values.any(
        (sub) => sub.relays.containsKey(url),
      );

      if (!hasActiveSubscriptions && managed.subscriptionIds.isEmpty) {
        managed.dispose();
        toRemove.add(url);
      }
    }

    for (final url in toRemove) {
      _sockets.remove(url);
    }
  }

  void _log(
    LogLevel level,
    String message, {
    String? subscriptionId,
    String? relayUrl,
    Exception? exception,
  }) {
    _logs.add(
      LogEntry(
        timestamp: DateTime.now(),
        level: level,
        message: message,
        subscriptionId: subscriptionId,
        relayUrl: relayUrl,
        exception: exception,
      ),
    );

    // Trim logs
    while (_logs.length > PoolConstants.maxLogEntries) {
      _logs.removeAt(0);
    }

    // Emit on exceptions
    if (exception != null) {
      _emit();
    }
  }

  void _emit() {
    if (_disposed) return;

    onStateChange(
      PoolState(
        subscriptions: Map.from(_subscriptions),
        logs: List.from(_logs),
      ),
    );
  }
}

/// Response wrapper for publish operations
class PublishRelayResponse {
  final wrapped = PublishResponse();
}

// ============================================================
// EVENT BUFFER (internal)
// ============================================================

/// Buffer for event deduplication and batching
class _EventBuffer {
  final String subscriptionId;
  final Duration batchWindow;
  final int totalRelayCount;
  final void Function(
    List<Map<String, dynamic>> events,
    Map<String, Set<String>> relaysForIds,
  )
  onFlush;

  Completer<List<Map<String, dynamic>>>? queryCompleter;
  Timer? eoseTimeoutTimer;

  final Map<String, Map<String, dynamic>> _eventsById = {};
  final Map<String, Set<String>> _relaysForEventId = {};
  final Set<String> _eoseReceived = {};
  Timer? _batchTimer;

  _EventBuffer({
    required this.subscriptionId,
    required this.batchWindow,
    required this.totalRelayCount,
    required this.onFlush,
    this.queryCompleter,
  });

  /// Whether this buffer has a blocking query waiting for results
  bool get _isBlocking => queryCompleter != null;

  void addEvent(String relayUrl, Map<String, dynamic> event) {
    final eventId = event['id'] as String?;
    if (eventId == null) return;

    // Track which relay sent this event
    _relaysForEventId.putIfAbsent(eventId, () => {}).add(relayUrl);

    // Add event if not already buffered
    if (!_eventsById.containsKey(eventId)) {
      _eventsById[eventId] = event;

      // Schedule batch flush for non-blocking subscriptions (streaming or _fetch)
      if (!_isBlocking) {
        _scheduleBatchFlush();
      }
    }
  }

  void markEose(String relayUrl) {
    _eoseReceived.add(relayUrl);

    if (_isBlocking) {
      // Blocking query: wait for all relays before completing the Future
      if (_eoseReceived.length >= totalRelayCount) {
        flush();
      }
    } else {
      // Streaming or _fetch: flush progressively on each EOSE
      if (_eventsById.isNotEmpty) {
        flush();
      }
    }
  }

  /// Whether all relays have sent EOSE
  bool get allEoseReceived => _eoseReceived.length >= totalRelayCount;

  void _scheduleBatchFlush() {
    if (_batchTimer?.isActive == true) return;
    _batchTimer = Timer(batchWindow, flush);
  }

  void flush() {
    _batchTimer?.cancel();
    _batchTimer = null;

    final events = _eventsById.values.toList();
    final relaysForIds = Map<String, Set<String>>.from(_relaysForEventId);

    // Emit events via callback
    if (events.isNotEmpty) {
      onFlush(events, relaysForIds);
    }

    // Complete query completer if blocking query is waiting
    if (queryCompleter != null && !queryCompleter!.isCompleted) {
      queryCompleter!.complete(List.from(events));
    }

    // Clear buffer for non-blocking subscriptions (streaming or _fetch)
    // Blocking queries keep buffer until unsubscribe for the Future return
    if (!_isBlocking) {
      _eventsById.clear();
      _relaysForEventId.clear();
    }
  }

  void dispose() {
    _batchTimer?.cancel();
    eoseTimeoutTimer?.cancel();

    if (queryCompleter != null && !queryCompleter!.isCompleted) {
      queryCompleter!.complete([]);
    }
  }
}
