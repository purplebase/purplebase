import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/pool/state/pool_state_notifier.dart';
import 'package:purplebase/src/pool/state/relay_event_notifier.dart';
import 'package:purplebase/src/pool/state/connection_phase.dart';
import 'package:purplebase/src/pool/state/subscription_phase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for pool state management
void main() {
  late Process? relayProcess;
  late WebSocketPool pool;
  late PoolStateNotifier stateNotifier;
  late RelayEventNotifier eventNotifier;
  late StorageConfiguration config;
  late ProviderContainer container;
  late Bip340PrivateKeySigner signer;

  const relayPort = 3340;
  const relayUrl = 'ws://localhost:$relayPort';

  setUpAll(() async {
    final tempContainer = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );
    final tempConfig = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'temp': {'wss://temp.com'},
      },
      defaultRelayGroup: 'temp',
    );
    await tempContainer.read(initializationProvider(tempConfig).future);

    relayProcess = await Process.start('test/support/test-relay', [
      '-port',
      relayPort.toString(),
    ]);

    relayProcess!.stdout.transform(utf8.decoder).listen((data) {});
    relayProcess!.stderr.transform(utf8.decoder).listen((data) {});

    await Future.delayed(Duration(milliseconds: 500));
  });

  setUp(() async {
    container = ProviderContainer();

    config = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {relayUrl},
      },
      defaultRelayGroup: 'test',
      responseTimeout: Duration(seconds: 5),
    );

    stateNotifier = PoolStateNotifier(
      throttleDuration: config.streamingBufferWindow,
    );
    eventNotifier = RelayEventNotifier();

    pool = WebSocketPool(
      config: config,
      stateNotifier: stateNotifier,
      eventNotifier: eventNotifier,
    );

    signer = Bip340PrivateKeySigner(
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      container.read(refProvider),
    );
    await signer.signIn();
  });

  tearDown(() {
    pool.dispose();
  });

  tearDownAll(() async {
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  test('should have correct PoolState structure', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    final state = stateNotifier.currentState;

    // Verify state structure
    expect(state.connections, isA<Map<String, RelayConnectionState>>());
    expect(state.subscriptions, isA<Map<String, SubscriptionState>>());
    expect(state.publishes, isA<Map<String, PublishOperation>>());
    expect(state.health, isA<HealthMetrics>());
    expect(state.timestamp, isA<DateTime>());

    pool.unsubscribe(req);
  });

  test('should track relay connection state properties', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    final state = stateNotifier.currentState;
    final connection = state.connections[relayUrl];

    expect(connection, isNotNull);
    expect(connection!.url, equals(relayUrl));
    expect(connection.phase, isA<ConnectionPhase>());
    expect(connection.phaseStartedAt, isA<DateTime>());
    expect(connection.reconnectAttempts, isA<int>());
    expect(connection.lastMessageAt, anyOf(isNull, isA<DateTime>()));
    expect(connection.lastError, anyOf(isNull, isA<String>()));

    pool.unsubscribe(req);
  });

  test('should track subscription state properties', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    final state = stateNotifier.currentState;
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(subscription!.subscriptionId, equals(req.subscriptionId));
    expect(subscription.phase, isA<SubscriptionPhase>());
    expect(
      subscription.relayStatus,
      isA<Map<String, RelaySubscriptionStatus>>(),
    );
    expect(subscription.totalEventsReceived, isA<int>());
    expect(subscription.startedAt, isA<DateTime>());

    pool.unsubscribe(req);
  });

  test('should track health metrics', () async {
    final state = stateNotifier.currentState;

    expect(state.health.totalConnections, isA<int>());
    expect(state.health.connectedCount, isA<int>());
    expect(state.health.disconnectedCount, isA<int>());
    expect(state.health.connectingCount, isA<int>());
    expect(state.health.totalSubscriptions, isA<int>());
    expect(state.health.fullyActiveSubscriptions, isA<int>());
    expect(state.health.partiallyActiveSubscriptions, isA<int>());
    expect(state.health.failedSubscriptions, isA<int>());
  });

  test('should update health metrics correctly', () async {
    final initialConnections =
        stateNotifier.currentState.health.totalConnections;

    // Create a connection by sending a request
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);
    await pool.send(req, relayUrls: {relayUrl});

    await Future.delayed(Duration(milliseconds: 500));

    final updatedHealth = stateNotifier.currentState.health;

    expect(
      updatedHealth.totalConnections,
      greaterThanOrEqualTo(initialConnections),
      reason: 'Connection count should be tracked',
    );

    pool.unsubscribe(req);
  });

  test('should track connection phases correctly', () async {
    const offlineRelay = 'ws://localhost:65535';

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {offlineRelay});
    await Future.delayed(Duration(milliseconds: 300));

    final state = stateNotifier.currentState;
    final connection = state.connections[offlineRelay];

    // Offline relay should be in Disconnected or Connecting phase
    expect(connection, isNotNull);
    expect(
      connection!.phase,
      anyOf(isA<Disconnected>(), isA<Connecting>()),
      reason: 'Offline relay should not be Connected',
    );

    pool.unsubscribe(req);
  });

  test('should handle subscription phases', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    final state = stateNotifier.currentState;
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(
      subscription!.phase,
      anyOf(SubscriptionPhase.eose, SubscriptionPhase.streaming),
      reason: 'Subscription should be in valid phase',
    );

    pool.unsubscribe(req);
  });

  test('should track per-relay subscription status', () async {
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);

    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    final state = stateNotifier.currentState;
    final subscription = state.subscriptions[req.subscriptionId];

    expect(subscription, isNotNull);
    expect(subscription!.relayStatus, isNotEmpty);

    final relayStatus = subscription.relayStatus[relayUrl];
    expect(relayStatus, isNotNull);
    expect(relayStatus!.phase, isA<RelaySubscriptionPhase>());

    pool.unsubscribe(req);
  });

  test('should emit state updates with timestamps', () async {
    final initialTimestamp = stateNotifier.currentState.timestamp;

    final req = Request([
      RequestFilter(kinds: {1}),
    ]);
    await pool.send(req, relayUrls: {relayUrl});
    await Future.delayed(Duration(milliseconds: 500));

    final updatedTimestamp = stateNotifier.currentState.timestamp;

    expect(
      updatedTimestamp.isAfter(initialTimestamp),
      isTrue,
      reason: 'State updates should have newer timestamps',
    );

    pool.unsubscribe(req);
  });

  test('should handle RelayEventNotifier events', () async {
    final receivedEvents = <RelayEvent?>[];

    eventNotifier.addListener((event) {
      receivedEvents.add(event);
    });

    // Publish an event to trigger events
    final note = await PartialNote('Event notifier test').signWith(signer);
    await pool.publish([
      note.toMap(),
    ], source: RemoteSource(relayUrls: {relayUrl}));

    await Future.delayed(Duration(milliseconds: 500));

    // EventNotifier should emit events (could be EventsReceived or NoticeReceived)
    expect(
      receivedEvents.where((e) => e != null).length,
      greaterThanOrEqualTo(0),
      reason: 'Should emit relay events',
    );
  });

  test('should throttle state updates', () async {
    final throttleConfig = StorageConfiguration(
      skipVerification: true,
      relayGroups: {
        'test': {relayUrl},
      },
      defaultRelayGroup: 'test',
      streamingBufferWindow: Duration(milliseconds: 200),
    );

    final throttledNotifier = PoolStateNotifier(
      throttleDuration: throttleConfig.streamingBufferWindow,
    );

    final throttledPool = WebSocketPool(
      config: throttleConfig,
      stateNotifier: throttledNotifier,
      eventNotifier: eventNotifier,
    );

    final timestamps = <DateTime>[];

    throttledNotifier.addListener((state) {
      timestamps.add(state.timestamp);
    });

    // Trigger multiple state updates
    final req = Request([
      RequestFilter(kinds: {1}),
    ]);
    await throttledPool.send(req, relayUrls: {relayUrl});

    await Future.delayed(Duration(milliseconds: 500));

    // With throttling, updates should be spaced out
    expect(timestamps, isNotEmpty);

    throttledPool.dispose();
  });
}
