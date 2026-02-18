import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.earlyClose);
  });

  tearDownAll(() => fixture.dispose());
  setUp(() => fixture.clear());

  group('Early close for ID-based requests', () {
    test('blocking ID query returns as soon as all IDs are found', () async {
      final note = await PartialNote(
        'early close test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish(
        [note.toMap()],
        source: RemoteSource(relays: {fixture.relayUrl}),
      );

      final stopwatch = Stopwatch()..start();
      final result = await fixture.blockingQuery(ids: {note.id});
      stopwatch.stop();

      expect(result, hasLength(1));
      expect(result.first['id'], equals(note.id));
    });

    test('multi-ID query returns when all found', () async {
      final notes = await Future.wait([
        PartialNote('early 1').signWith(fixture.signer),
        PartialNote('early 2').signWith(fixture.signer),
      ]);

      for (final note in notes) {
        await fixture.pool.publish(
          [note.toMap()],
          source: RemoteSource(relays: {fixture.relayUrl}),
        );
      }

      final result = await fixture.blockingQuery(
        ids: notes.map((n) => n.id).toSet(),
      );
      expect(result.length, equals(2));
    });
  });
}
