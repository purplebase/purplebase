import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

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
    test('returns published event', () async {
      final note = await PartialNote(
        'foreground test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish(
        [note.toMap()],
        relays: {fixture.relayUrl},
      );

      final result = await fixture.blockingQuery(ids: {note.id});
      expect(result, isNotEmpty);
      expect(result.first['id'], equals(note.id));
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

  group('Event callbacks', () {
    test('calls onEvents callback with published event', () async {
      final note = await PartialNote(
        'callback test ${DateTime.now().millisecondsSinceEpoch}',
      ).signWith(fixture.signer);

      await fixture.pool.publish(
        [note.toMap()],
        relays: {fixture.relayUrl},
      );

      await fixture.blockingQuery(ids: {note.id});

      expect(
        fixture.receivedEvents.any((e) => e['id'] == note.id),
        isTrue,
      );
    });
  });
}
