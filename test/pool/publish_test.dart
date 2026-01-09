import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for publish operations.
///
/// These tests verify the pool's ability to:
/// - Publish events to relays
/// - Track acceptance/rejection status
/// - Handle multiple events and relays
void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.publish);
  });

  tearDownAll(() => fixture.dispose());

  setUp(() => fixture.clear());

  group('Single event publishing', () {
    test('publishes event successfully with acceptance confirmation', () async {
      final note = await PartialNote(
        'test publish ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      final response = await fixture.pool.publish(
        [note.toMap()],
        source: RemoteSource(relays: {fixture.relayUrl}),
      );

      expect(response.wrapped.results, isNotEmpty);
      expect(response.wrapped.results.containsKey(note.id), isTrue);

      final eventStates = response.wrapped.results[note.id]!;
      expect(eventStates, isNotEmpty);
      expect(eventStates.first.accepted, isTrue);
      expect(eventStates.first.relayUrl, equals(fixture.relayUrl));
    });

    test('returns empty response for empty events', () async {
      final response = await fixture.pool.publish(
        [],
        source: RemoteSource(relays: {fixture.relayUrl}),
      );

      expect(response.wrapped.results, isEmpty);
    });
  });

  group('Multiple event publishing', () {
    test('publishes multiple events with all accepted', () async {
      final notes = await Future.wait([
        PartialNote('test 1').signWith(fixture.signer),
        PartialNote('test 2').signWith(fixture.signer),
        PartialNote('test 3').signWith(fixture.signer),
      ]);

      final response = await fixture.pool.publish(
        notes.map((n) => n.toMap()).toList(),
        source: RemoteSource(relays: {fixture.relayUrl}),
      );

      expect(response.wrapped.results.length, equals(3));

      for (final note in notes) {
        expect(response.wrapped.results.containsKey(note.id), isTrue);
        final eventStates = response.wrapped.results[note.id]!;
        expect(eventStates.first.accepted, isTrue);
      }
    });
  });

  group('Relay resolution', () {
    test('uses resolved relay URLs', () async {
      final note = await PartialNote(
        'test fallback ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      final response = await fixture.pool.publish(
        [note.toMap()],
        source: RemoteSource(relays: {fixture.relayUrl}),
      );

      expect(response.wrapped.results, isNotEmpty);
      expect(response.wrapped.results.containsKey(note.id), isTrue);
    });
  });
}
