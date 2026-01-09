import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for query operations.
///
/// These tests verify the pool's query capabilities:
/// - Foreground (blocking) vs background (streaming) queries
/// - Event delivery via callbacks
/// - Filter handling
void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(
      port: TestPorts.query,
      captureEvents: true,
    );
  });

  tearDownAll(() => fixture.dispose());

  setUp(() => fixture.clear());

  group('Foreground queries', () {
    test('executes foreground query and returns published event', () async {
      // Publish an event first
      final note = await PartialNote(
        'foreground query test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish(
        [note.toMap()],
        source: RemoteSource(relays: {fixture.relayUrl}),
      );

      // Query for it
      final req = Request([
        RequestFilter(kinds: {1}, ids: {note.id}),
      ]);

      final result = await fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: false),
      );

      expect(result, isNotEmpty);
      expect(result.first['id'], equals(note.id));
      expect(result.first['content'], contains('foreground query test'));
    });

    test('returns empty for empty filters', () async {
      final req = Request(<RequestFilter<Note>>[]);

      final result = await fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}),
      );

      expect(result, isEmpty);
    });

    test('returns empty for empty relay URLs', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      final result = await fixture.pool.query(
        req,
        source: RemoteSource(relays: <String>{}),
      );

      expect(result, isEmpty);
    });
  });

  group('Background queries', () {
    test('executes background query', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      final result = await fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      // Background queries return empty immediately
      expect(result, isEmpty);

      final state = await fixture.stateCapture.waitForSubscription(
        req.subscriptionId,
      );
      expect(state.subscriptions.containsKey(req.subscriptionId), isTrue);

      fixture.pool.unsubscribe(req);
    });
  });

  group('Streaming queries', () {
    test('executes streaming query', () async {
      final req = Request([RequestFilter(kinds: {1})]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      final state = await fixture.stateCapture.waitForEose(
        req.subscriptionId,
        fixture.relayUrl,
      );

      final sub = state.subscriptions[req.subscriptionId];
      expect(sub, isNotNull);
      expect(sub!.stream, isTrue);

      fixture.pool.unsubscribe(req);
    });
  });

  group('Event callbacks', () {
    test('calls onEvents callback with correct event data', () async {
      // Publish an event
      final note = await PartialNote(
        'callback test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish(
        [note.toMap()],
        source: RemoteSource(relays: {fixture.relayUrl}),
      );

      // Query for it
      final req = Request([
        RequestFilter(kinds: {1}, ids: {note.id}),
      ]);

      await fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: false),
      );

      // Verify callback received the event
      expect(fixture.receivedEvents, isNotEmpty);

      final matchingEvent = fixture.receivedEvents.where(
        (e) => e['id'] == note.id,
      );
      expect(matchingEvent, isNotEmpty);
      expect(matchingEvent.first['content'], contains('callback test'));
    });
  });
}
