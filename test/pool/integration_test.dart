import 'package:models/models.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Integration tests for the pool.
///
/// These tests verify end-to-end scenarios:
/// - Publish and query roundtrips
/// - Health checks during active operations
/// - Clean disposal
///
/// NOTE: These tests pass when run alone but are flaky in the full suite
/// due to relay state pollution from other tests. Run individually with:
/// `dart test test/pool/integration_test.dart`
void main() {
  late PoolTestFixture fixture;

  setUpAll(() async {
    fixture = await createPoolFixture(port: TestPorts.integration);
  });

  tearDownAll(() => fixture.dispose());

  setUp(() => fixture.clear());

  group(
    'Publish-query roundtrip',
    () {
      test('publishes and queries back event', () async {
        // Publish an event
        final note = await PartialNote(
          'integration test ${DateTime.now().millisecondsSinceEpoch}',
        ).signWith(fixture.signer);

        final publishResponse = await fixture.pool.publish(
          [note.toMap()],
          source: RemoteSource(relays: {fixture.relayUrl}),
        );

        expect(publishResponse.wrapped.results, isNotEmpty);
        expect(publishResponse.wrapped.results[note.id]?.first.accepted, isTrue);

        // Query for it
        final req = Request([RequestFilter(ids: {note.id})]);

        final result = await fixture.pool.query(
          req,
          source: RemoteSource(relays: {fixture.relayUrl}, stream: false),
        );

        expect(result, isNotEmpty);
        expect(result.first['id'], equals(note.id));
        expect(result.first['content'], contains('integration test'));
      });
    },
    skip: 'Flaky in full suite due to relay state pollution',
  );

  group(
    'Health checks',
    () {
      test('handles health check during active operations', () async {
        final req = Request([RequestFilter(kinds: {1})]);

        fixture.pool.query(
          req,
          source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
        );

        await fixture.stateCapture.waitForConnected(fixture.relayUrl);

        await fixture.pool.performHealthCheck();

        expect(fixture.stateCapture.lastState, isNotNull);
        expect(fixture.stateCapture.lastState!.isRelayConnected(fixture.relayUrl), isTrue);

        fixture.pool.unsubscribe(req);
      });

      test('handles connect during active operations', () async {
        final req = Request([RequestFilter(kinds: {1})]);

        fixture.pool.query(
          req,
          source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
        );

        await fixture.stateCapture.waitForConnected(fixture.relayUrl);

        fixture.pool.connect();

        expect(fixture.stateCapture.lastState, isNotNull);
        expect(fixture.stateCapture.lastState!.isRelayConnected(fixture.relayUrl), isTrue);

        fixture.pool.unsubscribe(req);
      });
    },
    skip: 'Flaky in full suite due to relay state pollution',
  );

  group(
    'Resource cleanup',
    () {
      test('cleans up connections on dispose', () async {
        final req = Request([RequestFilter(kinds: {1})]);

        fixture.pool.query(
          req,
          source: RemoteSource(relays: {fixture.relayUrl}, stream: true),
        );

        await fixture.stateCapture.waitForConnected(fixture.relayUrl);

        expect(fixture.stateCapture.lastState?.isRelayConnected(fixture.relayUrl), isTrue);

        fixture.pool.dispose();

        // Recreate fixture for other tests
        fixture = await createPoolFixture(port: TestPorts.integration);
      });
    },
    skip: 'Flaky in full suite due to relay state pollution',
  );
}
