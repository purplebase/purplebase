import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';

import 'fixtures.dart';

/// Provider to access ref in tests.
final refProvider = Provider((ref) => ref);

/// Test fixture for pool-level tests with real relay connections.
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

  Future<void> clear() async {
    process.kill(ProcessSignal.sigusr1);
    await Future.delayed(Duration(milliseconds: 50));
    stateCapture.clear();
    receivedEvents.clear();
  }

  Future<void> dispose() async {
    pool.dispose();
    process.kill();
    await process.exitCode;
    container.dispose();
  }

  Future<void> withSubscription({
    Set<int> kinds = const {1},
    Set<String>? authors,
    Set<String>? ids,
    bool stream = true,
    Duration timeout = const Duration(seconds: 5),
    required FutureOr<void> Function(PoolState state, RelaySubscription sub)
        test,
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

  Future<void> withStreamingSubscription({
    Set<int> kinds = const {1},
    Set<String>? authors,
    Set<String>? ids,
    Duration timeout = const Duration(seconds: 5),
    required FutureOr<void> Function(PoolState state, RelaySubscription sub)
        test,
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

  Future<List<Map<String, dynamic>>> blockingQuery({
    Set<int> kinds = const {1},
    Set<String>? authors,
    Set<String>? ids,
  }) async {
    final req = Request([
      RequestFilter(kinds: kinds, authors: authors, ids: ids),
    ]);
    return pool.query(
        req, source: RemoteSource(relays: {relayUrl}, stream: false));
  }

  Future<PublishRelayResponse> publishNote(String content) async {
    final note = await PartialNote(content).signWith(signer);
    return pool.publish([note.toMap()],
        source: RemoteSource(relays: {relayUrl}));
  }
}

/// Creates a pool test fixture with a running test relay.
///
/// [relayFlags] are passed directly to the test-relay binary, e.g.
/// `['--slowness', '500ms']` or `['--reject-events']`.
Future<PoolTestFixture> createPoolFixture({
  required int port,
  StorageConfiguration? config,
  bool captureEvents = false,
  List<String> relayFlags = const [],
}) async {
  final relayUrl = TestRelays.url(port);

  final process = await Process.start(
      'test/support/test-relay', ['-port', port.toString(), ...relayFlags]);
  process.stdout.transform(utf8.decoder).listen((_) {});
  process.stderr.transform(utf8.decoder).listen((_) {});
  await Future.delayed(Duration(milliseconds: 500));

  final tempContainer = ProviderContainer(
    overrides: [
      storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
    ],
  );
  final tempConfig = StorageConfiguration(
    skipVerification: true,
    defaultRelays: {
      'temp': {'wss://temp.com'}
    },
    defaultQuerySource:
        const LocalAndRemoteSource(relays: 'temp', stream: false),
  );
  await tempContainer.read(initializationProvider(tempConfig).future);

  final container = ProviderContainer(
    overrides: [
      storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
    ],
  );
  final stateCapture = PoolStateCapture();
  final receivedEvents = <Map<String, dynamic>>[];

  final poolConfig = config ??
      StorageConfiguration(
        skipVerification: true,
        defaultRelays: {
          'test': {relayUrl}
        },
        defaultQuerySource:
            const LocalAndRemoteSource(relays: 'test', stream: false),
        responseTimeout: const Duration(seconds: 5),
        streamingBufferDuration: const Duration(milliseconds: 100),
      );

  final pool = RelayPool(
    config: poolConfig,
    onStateChange: stateCapture.onState,
    onEvents: ({required req, required events, required relaysForIds}) {
      if (captureEvents) receivedEvents.addAll(events);
    },
  );

  final signer =
      Bip340PrivateKeySigner(TestKeys.privateKey, container.read(refProvider));
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

/// Creates a configured ProviderContainer for storage-level testing.
Future<ProviderContainer> createStorageTestContainer({
  StorageConfiguration? config,
}) async {
  final container = ProviderContainer(
    overrides: [
      storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
    ],
  );

  final storageConfig = config ??
      StorageConfiguration(
        skipVerification: true,
        defaultRelays: {
          'test': {'wss://test.relay'}
        },
        defaultQuerySource: LocalSource(),
      );

  await container.read(initializationProvider(storageConfig).future);
  return container;
}

extension StorageTestContainerExt on ProviderContainer {
  PurplebaseStorageNotifier get storage =>
      read(storageNotifierProvider.notifier) as PurplebaseStorageNotifier;

  Ref get ref => read(refProvider);

  Future<void> tearDown() async {
    await storage.clear();
    storage.dispose();
    storage.obliterate();
    dispose();
  }
}

/// Captures pool state changes for deterministic test synchronization.
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

  Future<PoolState> waitFor(
    bool Function(PoolState) predicate, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    for (final s in _states) {
      if (predicate(s)) return Future.value(s);
    }
    final completer = Completer<PoolState>();
    _waiters.add((predicate, completer));
    return completer.future.timeout(timeout,
        onTimeout: () =>
            throw TimeoutException('Timed out waiting for pool state', timeout));
  }

  Future<PoolState> waitForRelayStreaming(
    String subscriptionId,
    String relayUrl, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return waitFor((s) {
      final sub = s.subscriptions[subscriptionId];
      return sub?.relays[relayUrl]?.phase == RelaySubPhase.streaming;
    }, timeout: timeout);
  }

  Future<PoolState> waitForConnected(String relayUrl,
      {Duration timeout = const Duration(seconds: 5)}) {
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

  Future<PoolState> waitForSubscription(String subscriptionId,
      {Duration timeout = const Duration(seconds: 5)}) {
    return waitFor((s) => s.subscriptions.containsKey(subscriptionId),
        timeout: timeout);
  }

  Future<PoolState> waitForUnsubscribed(String subscriptionId,
      {Duration timeout = const Duration(seconds: 5)}) {
    return waitFor((s) => !s.subscriptions.containsKey(subscriptionId),
        timeout: timeout);
  }

  Future<PoolState> waitForEose(String subscriptionId, String relayUrl,
      {Duration timeout = const Duration(seconds: 5)}) {
    return waitFor((s) {
      final sub = s.subscriptions[subscriptionId];
      return sub?.relays[relayUrl]?.phase == RelaySubPhase.streaming;
    }, timeout: timeout);
  }

  PoolState? get lastState => _states.isEmpty ? null : _states.last;
  List<PoolState> get states => List.unmodifiable(_states);
  void clear() {
    _states.clear();
    _waiters.clear();
  }
}

extension PoolStateTestExtensions on PoolState {
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
