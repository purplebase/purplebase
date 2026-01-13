import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for pool-level buffer timing behavior.
///
/// Note: Source API tests (relationshipBufferWindow defaults, copyWith, equality)
/// are in models/test/storage/source_test.dart.
/// Core relationship batching logic is in models/test/core/nested_relationship_test.dart.
///
/// These tests verify WebSocket pool integration:
/// - streamingBufferDuration: events batched and flushed via onEvents callback
/// - Blocking vs streaming query behavior with real relay connections
void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(
      port: TestPorts.buffer,
      captureEvents: true,
    );
  });

  tearDownAll(() => fixture.dispose());

  setUp(() => fixture.clear());

  group('Pool event delivery', () {
    test('streaming query delivers events via onEvents callback', () async {
      // Publish an event first
      final note = await PartialNote(
        'streaming callback test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish([
        note.toMap(),
      ], source: RemoteSource(relays: {fixture.relayUrl}));

      // Query with streaming
      final req = Request([
        RequestFilter(ids: {note.id}),
      ]);

      fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
      );

      // Wait for EOSE which triggers flush
      await fixture.stateCapture.waitForEose(
        req.subscriptionId,
        fixture.relayUrl,
        timeout: Duration(seconds: 5),
      );

      // Wait additional buffer window time for flush
      await Future.delayed(Duration(milliseconds: 200));

      // Events should have been received via onEvents
      expect(
        fixture.receivedEvents.any((e) => e['id'] == note.id),
        isTrue,
        reason: 'Event should be delivered via onEvents callback',
      );

      fixture.pool.unsubscribe(req);
    });

    test('blocking query returns events directly without callback', () async {
      final note = await PartialNote(
        'blocking query test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish([
        note.toMap(),
      ], source: RemoteSource(relays: {fixture.relayUrl}));

      // Blocking query returns events directly
      final req = Request([
        RequestFilter(ids: {note.id}),
      ]);

      final result = await fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: false),
      );

      expect(result, isNotEmpty);
      expect(result.first['id'], equals(note.id));
    });
  });
}
