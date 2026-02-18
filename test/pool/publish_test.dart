import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.publish);
  });

  tearDownAll(() => fixture.dispose());
  setUp(() => fixture.clear());

  group('Single event publishing', () {
    test('publishes and gets acceptance', () async {
      final response = await fixture.publishNote(
        'test publish ${DateTime.now().millisecondsSinceEpoch}',
      );

      expect(response.wrapped.results, isNotEmpty);
      final eventStates = response.wrapped.results.values.first;
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
        expect(response.wrapped.results[note.id]!.first.accepted, isTrue);
      }
    });
  });
}
