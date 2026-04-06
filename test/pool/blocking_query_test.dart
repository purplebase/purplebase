import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.query);
  });

  tearDownAll(() => fixture.dispose());
  setUp(() => fixture.clear());

  group('Blocking queries (stream=false)', () {
    test('blocks until EOSE and returns events', () async {
      final note = await PartialNote(
        'blocking test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish(
        [note.toMap()],
        relays: {fixture.relayUrl},
      );

      final result = await fixture.blockingQuery(ids: {note.id});
      expect(result, isNotEmpty);
      expect(result.first['id'], equals(note.id));
    });

    test('auto-unsubscribes after completing', () async {
      final note = await PartialNote(
        'auto unsub test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish(
        [note.toMap()],
        relays: {fixture.relayUrl},
      );

      final req = Request([RequestFilter(ids: {note.id})]);
      await fixture.pool.query(
        req,
        source: RemoteSource(relays: {fixture.relayUrl}, stream: false),
      );

      await Future.delayed(Duration(milliseconds: 200));
      expect(
        fixture.stateCapture.lastState?.subscriptions
            .containsKey(req.subscriptionId),
        isFalse,
      );
    });

    test('returns empty list when no events match', () async {
      final result = await fixture.blockingQuery(
        ids: {'0000000000000000000000000000000000000000000000000000000000000000'},
      );
      expect(result, isEmpty);
    });

    test('returns multiple events', () async {
      final notes = await Future.wait([
        PartialNote('batch 1').signWith(fixture.signer),
        PartialNote('batch 2').signWith(fixture.signer),
      ]);

      for (final note in notes) {
        await fixture.pool.publish(
          [note.toMap()],
          relays: {fixture.relayUrl},
        );
      }

      final result = await fixture.blockingQuery(
        ids: notes.map((n) => n.id).toSet(),
      );
      expect(result.length, equals(2));
    });
  });
}
