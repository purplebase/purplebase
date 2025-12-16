import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for EventFilter functionality
void main() {
  late Process? relayProcess;
  late RelayPool pool;
  late PoolStateCapture stateCapture;
  late List<Map<String, dynamic>> receivedEvents;
  late ProviderContainer container;
  late Bip340PrivateKeySigner signer;

  const relayPort = 3342;
  const relayUrl = 'ws://localhost:$relayPort';

  setUpAll(() async {
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

    // Start test relay once for all tests
    relayProcess = await startTestRelay(relayPort);
  });

  setUp(() async {
    container = ProviderContainer();
    stateCapture = PoolStateCapture();
    receivedEvents = [];

    final config = testConfig(relayUrl);

    pool = RelayPool(
      config: config,
      onStateChange: stateCapture.onState,
      onEvents: ({required req, required events, required relaysForIds}) {
        receivedEvents.addAll(events);
      },
    );

    signer = Bip340PrivateKeySigner(
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      container.read(refProvider),
    );
    await signer.signIn();

    // Clear relay state between tests
    await relayProcess!.clear();
  });

  tearDown(() {
    pool.dispose();
  });

  tearDownAll(() async {
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  group('EventFilter', () {
    test('should filter out events that do not pass the filter', () async {
      // Publish two events - one with short content, one with long content
      final shortNote = await PartialNote('hi').signWith(signer);
      final longNote = await PartialNote(
        'This is a much longer note that should pass the filter',
      ).signWith(signer);

      await pool.publish(
        [shortNote.toMap(), longNote.toMap()],
        source: RemoteSource(relays: {relayUrl}),
      );

      // Query with a filter that only accepts content > 10 chars
      final req = Request([
        RequestFilter(kinds: {1}, authors: {signer.pubkey}),
      ]);

      await pool.query(
        req,
        source: RemoteSource(
          relays: {relayUrl},
          stream: false,
          eventFilter: (event) {
            final content = event['content'] as String?;
            return content != null && content.length > 10;
          },
        ),
      );

      // Should only receive the long note
      expect(receivedEvents.length, equals(1));
      expect(receivedEvents.first['id'], equals(longNote.id));
    });

    test('should pass all events when filter returns true', () async {
      final note1 = await PartialNote('note 1').signWith(signer);
      final note2 = await PartialNote('note 2').signWith(signer);

      await pool.publish(
        [note1.toMap(), note2.toMap()],
        source: RemoteSource(relays: {relayUrl}),
      );

      final req = Request([
        RequestFilter(kinds: {1}, authors: {signer.pubkey}),
      ]);

      await pool.query(
        req,
        source: RemoteSource(
          relays: {relayUrl},
          stream: false,
          eventFilter: (event) => true, // Accept all
        ),
      );

      expect(receivedEvents.length, equals(2));
    });

    test('should discard all events when filter returns false', () async {
      final note = await PartialNote('should be filtered').signWith(signer);

      await pool.publish(
        [note.toMap()],
        source: RemoteSource(relays: {relayUrl}),
      );

      final req = Request([
        RequestFilter(kinds: {1}, ids: {note.id}),
      ]);

      await pool.query(
        req,
        source: RemoteSource(
          relays: {relayUrl},
          stream: false,
          eventFilter: (event) => false, // Reject all
        ),
      );

      expect(receivedEvents, isEmpty);
    });

    test('should filter events in streaming mode', () async {
      // Start streaming query with filter
      final req = Request([
        RequestFilter(kinds: {1}, authors: {signer.pubkey}),
      ]);

      pool.query(
        req,
        source: RemoteSource(
          relays: {relayUrl},
          stream: true,
          eventFilter: (event) {
            final content = event['content'] as String?;
            return content?.contains('accept') ?? false;
          },
        ),
      );

      // Wait for subscription to be ready
      await stateCapture.waitForEose(req.subscriptionId, relayUrl);

      // Publish events after subscription is active
      final acceptedNote =
          await PartialNote('accept this note').signWith(signer);
      final rejectedNote =
          await PartialNote('reject this note').signWith(signer);

      await pool.publish(
        [acceptedNote.toMap(), rejectedNote.toMap()],
        source: RemoteSource(relays: {relayUrl}),
      );

      // Give time for events to arrive
      await Future.delayed(Duration(milliseconds: 200));

      pool.unsubscribe(req);

      // Should only have the accepted note
      final matchingEvents =
          receivedEvents.where((e) => e['id'] == acceptedNote.id);
      expect(matchingEvents, isNotEmpty);

      final rejectedEvents =
          receivedEvents.where((e) => e['id'] == rejectedNote.id);
      expect(rejectedEvents, isEmpty);
    });

    test('should work with no filter (null)', () async {
      final note = await PartialNote('no filter test').signWith(signer);

      await pool.publish(
        [note.toMap()],
        source: RemoteSource(relays: {relayUrl}),
      );

      final req = Request([
        RequestFilter(kinds: {1}, ids: {note.id}),
      ]);

      await pool.query(
        req,
        source: RemoteSource(
          relays: {relayUrl},
          stream: false,
          // No eventFilter specified
        ),
      );

      expect(receivedEvents.length, equals(1));
      expect(receivedEvents.first['id'], equals(note.id));
    });

    test('should filter by event kind', () async {
      final note = await PartialNote('kind 1 note').signWith(signer);

      await pool.publish(
        [note.toMap()],
        source: RemoteSource(relays: {relayUrl}),
      );

      final req = Request([
        RequestFilter(kinds: {1}, ids: {note.id}),
      ]);

      // Filter that only accepts kind 0 (profiles)
      await pool.query(
        req,
        source: RemoteSource(
          relays: {relayUrl},
          stream: false,
          eventFilter: (event) => event['kind'] == 0,
        ),
      );

      // Note is kind 1, so it should be filtered out
      expect(receivedEvents, isEmpty);
    });

    test('should clean up filter on unsubscribe', () async {
      final req = Request([
        RequestFilter(kinds: {1}),
      ]);

      pool.query(
        req,
        source: RemoteSource(
          relays: {relayUrl},
          stream: true,
          eventFilter: (event) => true,
        ),
      );

      await stateCapture.waitForSubscription(req.subscriptionId);

      // Unsubscribe should not throw
      expect(() => pool.unsubscribe(req), returnsNormally);

      // Subscription should be cleaned up
      final state = await stateCapture.waitForUnsubscribed(req.subscriptionId);
      expect(state.subscriptions.containsKey(req.subscriptionId), isFalse);
    });
  });
}

