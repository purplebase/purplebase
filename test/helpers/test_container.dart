import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';

import 'fixtures.dart';

/// Type alias for test callbacks that can be sync or async
typedef SubscriptionTest = FutureOr<void> Function(
  PoolState state,
  RelaySubscription sub,
);

/// Provider to access ref in tests
final refProvider = Provider((ref) => ref);

/// Test fixture for pool-level tests with real relay connections.
///
/// Usage:
/// ```dart
/// late PoolTestFixture fixture;
///
/// setUpAll(() async => fixture = await createPoolFixture(port: TestPorts.connection));
/// tearDownAll(() => fixture.dispose());
/// setUp(() => fixture.clear());
///
/// test('example', () async {
///   await fixture.withSubscription(
///     kinds: {1},
///     test: (state, sub) {
///       expect(state.isRelayConnected(fixture.relayUrl), isTrue);
///     },
///   );
/// });
/// ```
class PoolTestFixture {
  final Process process;
  final RelayPool pool;
  final PoolStateCapture stateCapture;
  final Bip340PrivateKeySigner signer;
  final String relayUrl;
  final ProviderContainer container;
  final List<Map<String, dynamic>> receivedEvents;

  PoolTestFixture._({
    required this.process,
    required this.pool,
    required this.stateCapture,
    required this.signer,
    required this.relayUrl,
    required this.container,
    required this.receivedEvents,
  });

  /// Clear relay state between tests
  Future<void> clear() async {
    process.kill(ProcessSignal.sigusr1);
    await Future.delayed(Duration(milliseconds: 50));
    stateCapture.clear();
    receivedEvents.clear();
  }

  /// Dispose all resources
  Future<void> dispose() async {
    pool.dispose();
    process.kill();
    await process.exitCode;
    container.dispose();
  }

  /// Execute a subscription test with automatic cleanup.
  ///
  /// Creates a subscription, waits for connection, runs the test,
  /// and automatically unsubscribes afterward.
  Future<void> withSubscription({
    Set<int> kinds = const {1},
    Set<String>? authors,
    Set<String>? ids,
    bool stream = true,
    Duration timeout = const Duration(seconds: 5),
    required SubscriptionTest test,
  }) async {
    final req = Request([
      RequestFilter(kinds: kinds, authors: authors, ids: ids),
    ]);

    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: stream));

    try {
      final state = await stateCapture.waitForSubscription(
        req.subscriptionId,
        timeout: timeout,
      );
      final sub = state.subscriptions[req.subscriptionId]!;
      await test(state, sub);
    } finally {
      pool.unsubscribe(req);
    }
  }

  /// Execute a streaming test that waits for EOSE before running assertions.
  Future<void> withStreamingSubscription({
    Set<int> kinds = const {1},
    Set<String>? authors,
    Set<String>? ids,
    Duration timeout = const Duration(seconds: 5),
    required SubscriptionTest test,
  }) async {
    final req = Request([
      RequestFilter(kinds: kinds, authors: authors, ids: ids),
    ]);

    pool.query(req, source: RemoteSource(relays: {relayUrl}, stream: true));

    try {
      final state = await stateCapture.waitForEose(
        req.subscriptionId,
        relayUrl,
        timeout: timeout,
      );
      final sub = state.subscriptions[req.subscriptionId]!;
      await test(state, sub);
    } finally {
      pool.unsubscribe(req);
    }
  }

  /// Execute a blocking (non-streaming) query and return events.
  Future<List<Map<String, dynamic>>> blockingQuery({
    Set<int> kinds = const {1},
    Set<String>? authors,
    Set<String>? ids,
  }) async {
    final req = Request([
      RequestFilter(kinds: kinds, authors: authors, ids: ids),
    ]);

    return pool.query(
      req,
      source: RemoteSource(relays: {relayUrl}, stream: false),
    );
  }

  /// Publish a note and return the response.
  Future<PublishRelayResponse> publishNote(String content) async {
    final note = await PartialNote(content).signWith(signer);
    return pool.publish(
      [note.toMap()],
      source: RemoteSource(relays: {relayUrl}),
    );
  }

  /// Publish events and return the response.
  Future<PublishRelayResponse> publish(List<Map<String, dynamic>> events) {
    return pool.publish(events, source: RemoteSource(relays: {relayUrl}));
  }
}

/// Creates a pool test fixture with a running test relay.
///
/// The fixture handles:
/// - Starting the test relay process
/// - Creating and configuring the pool
/// - Setting up state capture for deterministic testing
/// - Signing in a test signer
Future<PoolTestFixture> createPoolFixture({
  required int port,
  StorageConfiguration? config,
  bool captureEvents = false,
}) async {
  final relayUrl = TestRelays.url(port);

  // Start test relay
  final process = await Process.start('test/support/test-relay', [
    '-port',
    port.toString(),
  ]);

  // Suppress output
  process.stdout.transform(utf8.decoder).listen((_) {});
  process.stderr.transform(utf8.decoder).listen((_) {});

  // Wait for relay to be ready
  await Future.delayed(Duration(milliseconds: 500));

  // Initialize models (required before using pool)
  final tempContainer = ProviderContainer(
    overrides: [
      storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
    ],
  );
  final tempConfig = StorageConfiguration(
    skipVerification: true,
    defaultRelays: {
      'temp': {'wss://temp.com'},
    },
    defaultQuerySource: const LocalAndRemoteSource(
      relays: 'temp',
      stream: false,
    ),
  );
  await tempContainer.read(initializationProvider(tempConfig).future);

  // Create container and pool
  final container = ProviderContainer();
  final stateCapture = PoolStateCapture();
  final receivedEvents = <Map<String, dynamic>>[];

  final poolConfig = config ??
      StorageConfiguration(
        skipVerification: true,
        defaultRelays: {'test': {relayUrl}},
        defaultQuerySource: const LocalAndRemoteSource(
          relays: 'test',
          stream: false,
        ),
        responseTimeout: const Duration(seconds: 5),
        streamingBufferWindow: const Duration(milliseconds: 100),
      );

  final pool = RelayPool(
    config: poolConfig,
    onStateChange: stateCapture.onState,
    onEvents: ({required req, required events, required relaysForIds}) {
      if (captureEvents) receivedEvents.addAll(events);
    },
  );

  // Create and sign in signer
  final signer = Bip340PrivateKeySigner(
    TestKeys.privateKey,
    container.read(refProvider),
  );
  await signer.signIn();

  return PoolTestFixture._(
    process: process,
    pool: pool,
    stateCapture: stateCapture,
    signer: signer,
    relayUrl: relayUrl,
    container: container,
    receivedEvents: receivedEvents,
  );
}

/// Captures pool state changes for deterministic test synchronization.
///
/// Use this instead of Future.delayed() to wait for specific states.
class PoolStateCapture {
  final _states = <PoolState>[];
  final _waiters = <(bool Function(PoolState), Completer<PoolState>)>[];

  void onState(PoolState state) {
    _states.add(state);

    final toRemove = <int>[];
    for (var i = 0; i < _waiters.length; i++) {
      final (predicate, completer) = _waiters[i];
      if (predicate(state) && !completer.isCompleted) {
        completer.complete(state);
        toRemove.add(i);
      }
    }
    for (final i in toRemove.reversed) {
      _waiters.removeAt(i);
    }
  }

  /// Wait for a state matching the predicate. Checks history first.
  Future<PoolState> waitFor(
    bool Function(PoolState) predicate, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    // Check history first
    for (final s in _states) {
      if (predicate(s)) return Future.value(s);
    }

    final completer = Completer<PoolState>();
    _waiters.add((predicate, completer));

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException('Timed out waiting for pool state', timeout);
      },
    );
  }

  /// Wait for relay to be streaming (connected + EOSE received)
  Future<PoolState> waitForRelayStreaming(
    String subscriptionId,
    String relayUrl, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return waitFor((s) {
      final sub = s.subscriptions[subscriptionId];
      if (sub == null) return false;
      final relay = sub.relays[relayUrl];
      return relay?.phase == RelaySubPhase.streaming;
    }, timeout: timeout);
  }

  /// Wait for relay to be connected (loading or streaming)
  Future<PoolState> waitForConnected(
    String relayUrl, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return waitFor((s) {
      for (final sub in s.subscriptions.values) {
        final relay = sub.relays[relayUrl];
        if (relay != null &&
            (relay.phase == RelaySubPhase.loading ||
                relay.phase == RelaySubPhase.streaming)) {
          return true;
        }
      }
      return false;
    }, timeout: timeout);
  }

  /// Wait for subscription to exist
  Future<PoolState> waitForSubscription(
    String subscriptionId, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return waitFor(
      (s) => s.subscriptions.containsKey(subscriptionId),
      timeout: timeout,
    );
  }

  /// Wait for subscription to be removed
  Future<PoolState> waitForUnsubscribed(
    String subscriptionId, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return waitFor(
      (s) => !s.subscriptions.containsKey(subscriptionId),
      timeout: timeout,
    );
  }

  /// Wait for EOSE on a subscription from specific relay
  Future<PoolState> waitForEose(
    String subscriptionId,
    String relayUrl, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return waitFor((s) {
      final sub = s.subscriptions[subscriptionId];
      if (sub == null) return false;
      final relay = sub.relays[relayUrl];
      return relay?.phase == RelaySubPhase.streaming;
    }, timeout: timeout);
  }

  /// Get the last state (or null if none)
  PoolState? get lastState => _states.isEmpty ? null : _states.last;

  /// Get all captured states
  List<PoolState> get states => List.unmodifiable(_states);

  /// Clear state history
  void clear() {
    _states.clear();
    _waiters.clear();
  }
}

/// Extension on PoolState for test assertions
extension PoolStateTestExtensions on PoolState {
  /// Check if a relay is connected (connecting, loading or streaming) in any subscription
  bool isRelayConnected(String relayUrl) {
    for (final sub in subscriptions.values) {
      final relay = sub.relays[relayUrl];
      if (relay != null &&
          (relay.phase == RelaySubPhase.connecting ||
              relay.phase == RelaySubPhase.loading ||
              relay.phase == RelaySubPhase.streaming)) {
        return true;
      }
    }
    return false;
  }

  /// Get the number of connected relays across all subscriptions
  int get connectedCount {
    final connectedUrls = <String>{};
    for (final sub in subscriptions.values) {
      for (final entry in sub.relays.entries) {
        if (entry.value.phase == RelaySubPhase.loading ||
            entry.value.phase == RelaySubPhase.streaming) {
          connectedUrls.add(entry.key);
        }
      }
    }
    return connectedUrls.length;
  }
}

