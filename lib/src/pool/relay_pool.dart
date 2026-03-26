import 'dart:async';
import 'dart:convert';
import 'package:models/models.dart';

import 'event_buffer.dart';
import 'managed_socket.dart';
import 'pool_state.dart';
import 'relay_socket.dart';
import 'request_tracker.dart';

/// EOSE + grace window tracker for a single subscription.
///
/// Algorithm:
/// 1. Spawn REQs to ALL target relays in parallel
/// 2. Collect events as they arrive
/// 3. On FIRST EOSE from any relay: start grace window timer (default 200ms)
/// 4. When grace window expires: flush all collected events
/// 5. Events arriving after grace window are merged via storage layer
/// 6. If NO EOSE before absolute timeout: flush whatever is buffered
class _SubscriptionEoseTracker {
  final String subId;
  final Duration graceWindow;
  final Duration absoluteTimeout;
  final void Function(String subId) onFlush;

  Timer? _graceTimer;
  Timer? _absoluteTimer;
  bool _firstEoseReceived = false;
  bool _flushed = false;

  _SubscriptionEoseTracker({
    required this.subId,
    required this.graceWindow,
    required this.absoluteTimeout,
    required this.onFlush,
  }) {
    _absoluteTimer = Timer(absoluteTimeout, _flush);
  }

  void onEose(String relayUrl) {
    if (_flushed) return;
    if (!_firstEoseReceived) {
      _firstEoseReceived = true;
      _graceTimer = Timer(graceWindow, _flush);
    }
  }

  void _flush() {
    if (_flushed) return;
    _flushed = true;
    _graceTimer?.cancel();
    _absoluteTimer?.cancel();
    onFlush(subId);
  }

  bool get hasFlushed => _flushed;

  void dispose() {
    _graceTimer?.cancel();
    _absoluteTimer?.cancel();
  }
}

/// Pending publish operation.
class PendingPublish {
  final String eventId;
  final String relayUrl;
  final Completer<PublishResult> completer;
  final Timer timeoutTimer;

  PendingPublish({
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

/// Response wrapper for publish operations.
class PublishRelayResponse {
  final wrapped = PublishResponse();
}

/// WebSocket relay pool — manages connections, subscriptions, event buffering.
///
/// Features vs old pool:
/// - EOSE + grace window algorithm (first EOSE starts 200ms window)
/// - `since` on ALL REQ sends (not just streaming reconnections)
/// - Early close for ID-based requests when all IDs received
/// - Pool-level request deduplication via [RequestTracker]
/// - Connectivity-aware (pauses/resumes on online/offline)
class RelayPool {
  final StorageConfiguration config;
  final PoolConfiguration poolConfig;
  final void Function(PoolState state) onStateChange;
  final void Function({
    required Request req,
    required List<Map<String, dynamic>> events,
    required Map<String, Set<String>> relaysForIds,
  }) onEvents;

  final Map<String, RelaySubscription> _subscriptions = {};
  final Map<String, RelaySubscription> _closedSubscriptions = {};
  final List<LogEntry> _logs = [];

  final Map<String, ManagedSocket> _sockets = {};
  final Map<String, PendingPublish> _pendingPublishes = {};
  final Map<String, EventBuffer> _eventBuffers = {};
  final Map<String, _SubscriptionEoseTracker> _eoseTrackers = {};
  final RequestTracker _requestTracker = RequestTracker();

  bool _disposed = false;
  bool _isOffline = false;

  RelayPool({
    required this.config,
    this.poolConfig = const PoolConfiguration(),
    required this.onStateChange,
    required this.onEvents,
  });

  // ============================================================
  // PUBLIC API
  // ============================================================

  /// Query relays.
  ///
  /// For `stream=false`: blocks until EOSE grace window, returns events.
  /// For `stream=true`: returns [] immediately, events flow via onEvents.
  Future<List<Map<String, dynamic>>> query(
    Request req, {
    RemoteSource source = const RemoteSource(),
  }) async {
    if (source.relays is! Iterable<String>) return [];
    final relayUrls = (source.relays as Iterable<String>).toSet();
    if (relayUrls.isEmpty) return [];

    // Pool-level dedup: check if exact same filters are already active
    final existingSubId = _requestTracker.findExact(req.filters);
    if (existingSubId != null && source.stream) {
      return [];
    }

    if (source.stream) {
      _createSubscription(
        req,
        relayUrls: relayUrls,
        stream: true,
        queryCompleter: null,
      );
      return [];
    }

    final completer = Completer<List<Map<String, dynamic>>>();
    _createSubscription(
      req,
      relayUrls: relayUrls,
      stream: false,
      queryCompleter: completer,
    );
    return completer.future;
  }

  /// Close subscriptions to specified relays.
  Set<String> closeSubscriptionsToRelays(Set<String> relayUrls) {
    if (relayUrls.isEmpty) return {};

    final cancelledSubIds = <String>{};

    for (final subId in _subscriptions.keys.toList()) {
      final sub = _subscriptions[subId];
      if (sub == null) continue;

      final affectedRelays =
          sub.relays.keys.where(relayUrls.contains).toSet();
      if (affectedRelays.isEmpty) continue;

      for (final url in affectedRelays) {
        final managed = _sockets[url];
        if (managed != null) {
          if (managed.socket.isConnected) {
            managed.socket.sendClose(subId);
          }
          managed.subscriptionIds.remove(subId);
          if (managed.subscriptionIds.isEmpty) {
            managed.reconnectTimer?.cancel();
          }
        }
      }

      final remainingRelays = Map<String, RelaySubState>.from(sub.relays)
        ..removeWhere((url, _) => affectedRelays.contains(url));

      if (remainingRelays.isEmpty) {
        _eventBuffers[subId]?.dispose();
        _eventBuffers.remove(subId);
        _eoseTrackers[subId]?.dispose();
        _eoseTrackers.remove(subId);
        _requestTracker.unregister(subId);
        _subscriptions.remove(subId);

        _closedSubscriptions[subId] = sub.copyWith(
          closedAt: DateTime.now(),
          relays: {
            for (final url in sub.relays.keys)
              url: sub.relays[url]!.copyWith(phase: RelaySubPhase.closed),
          },
        );

        while (_closedSubscriptions.length >
            PoolConstants.maxClosedSubscriptions) {
          _closedSubscriptions.remove(_closedSubscriptions.keys.first);
        }

        cancelledSubIds.add(subId);
        _log(LogLevel.info, 'Subscription closed (all relays removed)',
            subscriptionId: subId);
      } else {
        _subscriptions[subId] = sub.copyWith(relays: remainingRelays);
        _log(LogLevel.info,
            'Removed ${affectedRelays.length} relay(s), ${remainingRelays.length} remaining',
            subscriptionId: subId);
      }
    }

    _cleanupIdleSockets();
    _emit();
    return cancelledSubIds;
  }

  /// Unsubscribe from a request.
  void unsubscribe(Request req) {
    final subId = req.subscriptionId;
    final sub = _subscriptions[subId];
    if (sub == null) return;

    final closedAt = DateTime.now();

    final closedRelays = <String, RelaySubState>{};
    for (final entry in sub.relays.entries) {
      closedRelays[entry.key] =
          entry.value.copyWith(phase: RelaySubPhase.closed);
    }

    for (final url in sub.relays.keys) {
      final managed = _sockets[url];
      if (managed != null) {
        if (managed.socket.isConnected) {
          managed.socket.sendClose(subId);
        }
        managed.subscriptionIds.remove(subId);
        if (managed.subscriptionIds.isEmpty) {
          managed.reconnectTimer?.cancel();
        }
      }
    }

    _eventBuffers[subId]?.dispose();
    _eventBuffers.remove(subId);
    _eoseTrackers[subId]?.dispose();
    _eoseTrackers.remove(subId);
    _requestTracker.unregister(subId);

    _subscriptions.remove(subId);
    _closedSubscriptions[subId] = sub.copyWith(
      closedAt: closedAt,
      relays: closedRelays,
    );

    while (_closedSubscriptions.length > PoolConstants.maxClosedSubscriptions) {
      _closedSubscriptions.remove(_closedSubscriptions.keys.first);
    }

    _cleanupIdleSockets();
    _emit();
  }

  /// Publish events to relays.
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

    _cleanupIdleSockets();
    return response;
  }

  /// Health check — called by heartbeat from main isolate.
  Future<void> performHealthCheck({bool force = false}) async {
    if (_disposed || _isOffline) return;

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
            final socketActivity = _sockets[url]?.socket.lastActivityAt;
            final lastActivity = relayState.lastEventAt ?? socketActivity;
            if (lastActivity != null) {
              final idle = now.difference(lastActivity);
              if (idle > PoolConstants.pingIdleThreshold) {
                await _pingRelay(subId, url);
              }
            }

          case RelaySubPhase.connecting:
            break;

          case RelaySubPhase.waiting:
            final managed = _sockets[url];
            if (managed?.reconnectTimer?.isActive != true) {
              _connectRelay(subId, url);
            }

          case RelaySubPhase.disconnected:
            _connectRelay(subId, url);

          case RelaySubPhase.failed:
          case RelaySubPhase.closed:
            break;
        }
      }
    }
  }

  /// Force immediate reconnection — called on app resume.
  void connect() {
    if (_disposed) return;
    _isOffline = false;

    for (final entry in _subscriptions.entries) {
      final subId = entry.key;
      final sub = entry.value;

      for (final relayEntry in sub.relays.entries) {
        final url = relayEntry.key;
        final relayState = relayEntry.value;

        if (relayState.phase == RelaySubPhase.disconnected ||
            relayState.phase == RelaySubPhase.waiting ||
            relayState.phase == RelaySubPhase.failed) {
          final managed = _sockets[url];
          if (managed != null) {
            managed.reconnectTimer?.cancel();
            managed.reconnectAttempts = 0;
            managed.lastError = null;
          }

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

  /// Disconnect all relays — called on app pause.
  void disconnect() {
    if (_disposed) return;

    for (final managed in _sockets.values) {
      managed.reconnectTimer?.cancel();
    }

    for (final entry in _subscriptions.entries) {
      final subId = entry.key;
      final sub = entry.value;

      for (final url in sub.relays.keys) {
        final managed = _sockets[url];
        if (managed?.socket.isConnected == true) {
          managed!.socket.sendClose(subId);
        }

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

    for (final managed in _sockets.values) {
      managed.socket.disconnect();
    }

    _emit();
  }

  /// Handle connectivity status changes from the main isolate.
  void setConnectivity(bool isOnline) {
    if (isOnline && _isOffline) {
      _isOffline = false;
      connect();
    } else if (!isOnline && !_isOffline) {
      _isOffline = true;
      for (final managed in _sockets.values) {
        managed.reconnectTimer?.cancel();
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final buffer in _eventBuffers.values) {
      buffer.dispose();
    }
    _eventBuffers.clear();

    for (final tracker in _eoseTrackers.values) {
      tracker.dispose();
    }
    _eoseTrackers.clear();

    for (final pending in _pendingPublishes.values) {
      pending.dispose();
    }
    _pendingPublishes.clear();

    for (final managed in _sockets.values) {
      managed.dispose();
    }
    _sockets.clear();

    _subscriptions.clear();
    _closedSubscriptions.clear();
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

    final relays = <String, RelaySubState>{};
    for (final url in relayUrls) {
      relays[url] = const RelaySubState(phase: RelaySubPhase.disconnected);
    }

    final sub = RelaySubscription(
      id: subId,
      request: req,
      stream: stream,
      startedAt: DateTime.now(),
      relays: relays,
    );
    _subscriptions[subId] = sub;
    _requestTracker.register(subId, req.filters);

    _eventBuffers[subId] = EventBuffer(
      subscriptionId: subId,
      batchWindow: config.streamingBufferDuration,
      totalRelayCount: relayUrls.length,
      queryCompleter: queryCompleter,
      onFlush: (events, relaysForIds) {
        if (events.isNotEmpty) {
          onEvents(req: req, events: events, relaysForIds: relaysForIds);
        }
      },
      onEose: (eventCount, relayUrl) {
        final duration = DateTime.now().difference(sub.startedAt);
        final seconds = (duration.inMilliseconds / 1000).toStringAsFixed(2);
        _log(
          LogLevel.info,
          'EOSE: $eventCount events (${seconds}s)',
          subscriptionId: subId,
          relayUrl: relayUrl,
        );
      },
    );

    for (final url in relayUrls) {
      _connectRelay(subId, url);
    }

    _emit();
  }

  // ============================================================
  // CONNECTION MANAGEMENT
  // ============================================================

  void _connectRelay(String subId, String url) {
    if (_isOffline) return;

    final sub = _subscriptions[subId];
    if (sub == null) return;

    final relayState = sub.relays[url];
    if (relayState == null) return;

    if (relayState.phase == RelaySubPhase.connecting ||
        relayState.phase == RelaySubPhase.loading ||
        relayState.phase == RelaySubPhase.streaming ||
        relayState.phase == RelaySubPhase.failed) {
      return;
    }

    _updateRelayState(
      subId,
      url,
      relayState.copyWith(phase: RelaySubPhase.connecting),
    );

    final managed = _getOrCreateSocket(url);
    managed.subscriptionIds.add(subId);

    if (!managed.socket.isConnected) {
      managed.socket
          .connect()
          .then((_) => _onSocketConnected(url))
          .catchError((e) => _onSocketError(url, e.toString()));
    } else {
      _sendSubscription(subId, url);
    }
  }

  ManagedSocket _getOrCreateSocket(String url) {
    return _sockets.putIfAbsent(url, () {
      final socket = RelaySocket(
        url: url,
        onMessage: (msg) => _handleMessage(url, msg),
        onDisconnect: (err) => _onSocketDisconnected(url, err),
      );
      return ManagedSocket(url: url, socket: socket);
    });
  }

  void _onSocketConnected(String url) {
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

    _updateRelayState(
      subId,
      url,
      relayState.copyWith(phase: RelaySubPhase.loading),
    );

    // Build filters with `since` on ALL REQ sends (not just streaming)
    var filters = sub.request
        .toMaps()
        .map((f) => Map<String, dynamic>.from(f))
        .toList();

    if (relayState.lastEventAt != null) {
      final since =
          (relayState.lastEventAt!.millisecondsSinceEpoch ~/ 1000) - 1;
      filters = filters.map((f) {
        final newFilter = Map<String, dynamic>.from(f);
        final existingSince = newFilter['since'] as int?;
        if (existingSince == null || since > existingSince) {
          // Don't widen the query if `until` is before computed `since`
          final existingUntil = newFilter['until'] as int?;
          if (existingUntil == null || since < existingUntil) {
            newFilter['since'] = since;
          }
        }
        return newFilter;
      }).toList();
    }

    final sent = managed.socket.sendReq(subId, filters);
    if (!sent) {
      _log(
        LogLevel.warning,
        'Failed to send REQ (socket broken)',
        subscriptionId: subId,
        relayUrl: url,
      );
      managed.socket.disconnect();
      _onSocketDisconnected(url, 'Send failed');
      return;
    }

    // Start EOSE tracker after first successful REQ
    if (!_eoseTrackers.containsKey(subId)) {
      final relayCount = sub.relays.length;
      final timeout = relayCount == 1
          ? poolConfig.eoseTimeoutSingleRelay
          : poolConfig.eoseTimeout;

      _eoseTrackers[subId] = _SubscriptionEoseTracker(
        subId: subId,
        graceWindow: poolConfig.eoseGraceWindow,
        absoluteTimeout: timeout,
        onFlush: _handleGraceWindowFlush,
      );
    }
  }

  void _onSocketDisconnected(String url, String? error) {
    final managed = _sockets[url];
    if (managed == null) return;

    managed.reconnectAttempts++;
    managed.lastError = error;

    final shouldFail = managed.reconnectAttempts >= PoolConstants.maxRetries;
    final newPhase = shouldFail ? RelaySubPhase.failed : RelaySubPhase.waiting;

    for (final subId in managed.subscriptionIds.toList()) {
      final sub = _subscriptions[subId];
      if (sub == null) continue;

      final relayState = sub.relays[url];
      if (relayState == null) continue;
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
        emit: false,
      );
    }

    if (shouldFail) {
      for (final subId in managed.subscriptionIds) {
        _log(
          LogLevel.error,
          'Relay failed after ${managed.reconnectAttempts} attempts',
          subscriptionId: subId,
          relayUrl: url,
        );
      }
    } else if (!_isOffline) {
      _scheduleReconnect(url);
    }

    _emit();
  }

  void _onSocketError(String url, String error) {
    _onSocketDisconnected(url, error);
  }

  void _scheduleReconnect(String url) {
    final managed = _sockets[url];
    if (managed == null) return;

    managed.reconnectTimer?.cancel();

    final delay = PoolConstants.getBackoffDelay(managed.reconnectAttempts);
    if (delay == null) return;

    managed.reconnectTimer = Timer(delay, () {
      if (!_disposed && !_isOffline) {
        _reconnectRelay(url);
      }
    });
  }

  void _reconnectRelay(String url) {
    final managed = _sockets[url];
    if (managed == null) return;

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
          break;
      }
    } catch (e) {
      final managed = _sockets[url];
      final subIds = managed?.subscriptionIds ?? <String>{};
      if (subIds.isEmpty) {
        _log(LogLevel.warning, 'Failed to parse message',
            relayUrl: url, exception: Exception(e.toString()));
      } else {
        for (final subId in subIds) {
          _log(LogLevel.warning, 'Failed to parse message',
              subscriptionId: subId,
              relayUrl: url,
              exception: Exception(e.toString()));
        }
      }
    }
  }

  void _handleEvent(String url, String subId, Map<String, dynamic> event) {
    if (subId == ManagedSocket.pingSubId) return;

    final sub = _subscriptions[subId];
    if (sub == null) return;

    final buffer = _eventBuffers[subId];
    if (buffer == null) return;

    final relayState = sub.relays[url];
    if (relayState != null) {
      _updateRelayState(
        subId,
        url,
        relayState.copyWith(lastEventAt: DateTime.now()),
        emit: false,
      );
    }

    if (buffer.addEvent(url, event)) {
      _subscriptions[subId] = sub.copyWith(eventCount: sub.eventCount + 1);
    }

    // Early close for ID-based requests
    if (_shouldCloseEarly(subId)) {
      _handleEarlyCompletion(subId);
    }
  }

  void _handleEose(String url, String subId) {
    if (subId == ManagedSocket.pingSubId) {
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

    final managed = _sockets[url];
    if (managed != null) {
      if (managed.reconnectAttempts > 0) {
        _log(
          LogLevel.info,
          'Reconnected after ${managed.reconnectAttempts} attempt(s)',
          subscriptionId: subId,
          relayUrl: url,
        );
      }
      managed.reconnectAttempts = 0;
      managed.lastError = null;
    }

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

    // Feed to the EOSE tracker (grace window algorithm)
    _eoseTrackers[subId]?.onEose(url);

    // Feed to buffer for EOSE logging
    buffer.markEose(url);

    // For streaming subscriptions: after all EOSEs, the tracker has already
    // handled the flush via the grace window.
    if (buffer.allEoseReceived && !sub.stream) {
      // Non-streaming: buffer.markEose handles the flush and completer
      _eoseTrackers[subId]?.dispose();
      _eoseTrackers.remove(subId);
      unsubscribe(sub.request);
    }
  }

  /// Grace window expired — flush buffered events.
  void _handleGraceWindowFlush(String subId) {
    final buffer = _eventBuffers[subId];
    if (buffer == null) return;

    final sub = _subscriptions[subId];
    if (sub == null) return;

    if (!buffer.hasFlushed) {
      buffer.flush();
    }

    if (!sub.stream) {
      _eoseTrackers[subId]?.dispose();
      _eoseTrackers.remove(subId);
      unsubscribe(sub.request);
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
    if (subId == ManagedSocket.pingSubId) {
      final managed = _sockets[url];
      if (managed?.pingCompleter != null &&
          !managed!.pingCompleter!.isCompleted) {
        managed.pingCompleter!.complete();
      }
      return;
    }

    final sub = _subscriptions[subId];
    if (sub == null) return;

    if (sub.relays.containsKey(url)) {
      _sendSubscription(subId, url);
    }
  }

  // ============================================================
  // EARLY CLOSE FOR ID-BASED REQUESTS
  // ============================================================

  bool _shouldCloseEarly(String subId) {
    final sub = _subscriptions[subId];
    if (sub == null || sub.stream) return false;

    final buffer = _eventBuffers[subId];
    if (buffer == null) return false;

    final requestedIds = <String>{};
    for (final filter in sub.request.filters) {
      requestedIds.addAll(filter.ids);
    }

    if (requestedIds.isEmpty) return false;

    return requestedIds.every(buffer.hasEvent);
  }

  void _handleEarlyCompletion(String subId) {
    final buffer = _eventBuffers[subId];
    if (buffer == null) return;

    final sub = _subscriptions[subId];
    if (sub == null) return;

    _eoseTrackers[subId]?.dispose();
    _eoseTrackers.remove(subId);

    buffer.flush();
    unsubscribe(sub.request);
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

    _pendingPublishes[key] = PendingPublish(
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

    if (managed.pingCompleter != null && !managed.pingCompleter!.isCompleted) {
      return;
    }

    managed.pingCompleter = Completer<void>();

    final sent = managed.socket.sendPing(ManagedSocket.pingSubId);
    if (!sent) {
      _log(LogLevel.warning, 'Failed to send ping (socket broken)',
          subscriptionId: subId, relayUrl: url);
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
          _log(LogLevel.warning, 'Zombie connection detected (ping timeout)',
              subscriptionId: subId, relayUrl: url);
          managed.socket.disconnect();
          _onSocketDisconnected(url, 'Ping timeout');
        },
      );
    } finally {
      if (!timedOut && managed.socket.isConnected) {
        managed.socket.sendClose(ManagedSocket.pingSubId);
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

    if (emit && phaseChanged) {
      _emit();
    }
  }

  void _cleanupIdleSockets() {
    final toRemove = <String>[];

    for (final entry in _sockets.entries) {
      final url = entry.key;
      final managed = entry.value;

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

    while (_logs.length > PoolConstants.maxLogEntries) {
      _logs.removeAt(0);
    }

    if (exception != null) {
      _emit();
    }
  }

  void _emit() {
    if (_disposed) return;

    onStateChange(
      PoolState(
        subscriptions: Map.from(_subscriptions),
        closedSubscriptions: Map.from(_closedSubscriptions),
        logs: List.from(_logs),
      ),
    );
  }
}
