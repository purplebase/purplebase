import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:purplebase/src/isolate.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for remote query operations via isolate.
void main() {
  Process? relayProcess;
  final relayPort = TestPorts.isolateRemote + 1; // Use different port
  final relayUrl = 'ws://127.0.0.1:$relayPort';

  late ProviderContainer container;
  late StorageNotifier storage;
  late Bip340PrivateKeySigner signer;
  late Note testNote1, testNote2;

  Future<void> clearRelay() async {
    final clearNote = await PartialNote('CLEAR_DB').signWith(signer);
    await storage.publish({clearNote}, source: RemoteSource(relays: {relayUrl}));
    await Future.delayed(Duration(milliseconds: 100));
  }

  setUpAll(() async {
    relayProcess = await Process.start('test/support/test-relay', [
      '-port',
      relayPort.toString(),
    ]);

    relayProcess!.stdout.transform(utf8.decoder).listen((_) {});
    relayProcess!.stderr.transform(utf8.decoder).listen((_) {});

    await Future.delayed(Duration(milliseconds: 500));

    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    final config = StorageConfiguration(
      skipVerification: true,
      defaultRelays: {
        'primary': {relayUrl},
        'offline': {TestRelays.offline},
      },
      defaultQuerySource: LocalAndRemoteSource(
        relays: 'primary',
        stream: false,
      ),
      responseTimeout: Duration(milliseconds: 200),
    );

    await container.read(initializationProvider(config).future);
    storage = container.read(storageNotifierProvider.notifier);

    signer = Bip340PrivateKeySigner(
      Utils.generateRandomHex64(),
      container.read(refProvider),
    );
    await signer.signIn();

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    testNote1 = await PartialNote(
      'Test note for remote query $timestamp',
      tags: {'test', 'remote'},
    ).signWith(signer);

    testNote2 = await PartialNote(
      'Second test note $timestamp',
      tags: {'test', 'batch'},
    ).signWith(signer);

    await clearRelay();

    // Publish test events
    final publishResponse = await storage.publish(
      {testNote1, testNote2},
      source: RemoteSource(relays: {relayUrl}),
    );

    for (final event in [testNote1, testNote2]) {
      final states = publishResponse.results[event.id];
      if (states == null || states.isEmpty || !states.every((s) => s.accepted)) {
        throw Exception('Event not accepted: ${event.id}');
      }
    }
  });

  tearDownAll(() async {
    storage.dispose();
    container.dispose();
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  group('Query by filters', () {
    test('queries events by ID from relay', () async {
      final result = await storage.query(
        RequestFilter(ids: {testNote1.id}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );

      expect(result, isNotEmpty);
      final foundEvent = result.where((e) => e.id == testNote1.id).firstOrNull;
      expect(foundEvent, isNotNull);
      expect(foundEvent!.event.content, contains('Test note for remote query'));
    });

    test('queries events by kind from relay', () async {
      final result = await storage.query(
        RequestFilter(kinds: {1}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );

      expect(result, isNotEmpty);
      expect(result.every((e) => e.event.kind == 1), isTrue);
    });

    test('queries events by author from relay', () async {
      final result = await storage.query(
        RequestFilter(authors: {signer.pubkey}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );

      expect(result, isNotEmpty);
      expect(result.every((e) => e.event.pubkey == signer.pubkey), isTrue);
    });

    test('queries events with tags from relay', () async {
      final result = await storage.query(
        RequestFilter(
          tags: {
            '#t': {'test'},
          },
        ).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );

      expect(result, isNotEmpty);
    });
  });

  group('Query with limits', () {
    test('handles query with time limits', () async {
      final now = DateTime.now();
      final oneHourAgo = now.subtract(Duration(hours: 1));

      final result = await storage.query(
        RequestFilter(
          authors: {signer.pubkey},
          since: oneHourAgo,
          limit: 10,
        ).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );

      expect(result.length, lessThanOrEqualTo(10));
    });
  });

  group('Error handling', () {
    test(
      'handles offline relay gracefully',
      () async {
        final result = await storage.query(
          RequestFilter(authors: {signer.pubkey}).toRequest(),
          source: RemoteSource(relays: 'offline', stream: false),
        );

        expect(result, isA<List>());
      },
      skip: 'Offline relay test is timing-sensitive and flaky in CI',
    );

    test('handles empty query filters', () async {
      final result = await storage.query(
        RequestFilter().toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );

      expect(result, isA<List>());
    });
  });

  group('Local persistence', () {
    test('persists remote query results to local storage', () async {
      final uniqueNote = await PartialNote(
        'Local cache test ${DateTime.now().millisecondsSinceEpoch}',
        tags: {'cache_test'},
      ).signWith(signer);

      await storage.publish(
        {uniqueNote},
        source: RemoteSource(relays: {relayUrl}),
      );

      // Query from remote - should save to local
      final remoteResult = await storage.query(
        RequestFilter(ids: {uniqueNote.id}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );
      expect(remoteResult, isNotEmpty);
      expect(remoteResult.first.id, equals(uniqueNote.id));

      // Query from local - should be persisted
      final localResult = await storage.query(
        RequestFilter(ids: {uniqueNote.id}).toRequest(),
        source: LocalSource(),
      );
      expect(localResult, isNotEmpty);
      expect(localResult.first.id, equals(uniqueNote.id));
    });

    test('deduplicates events from multiple relays', () async {
      // Publish to relay
      await storage.publish({testNote1}, source: RemoteSource(relays: {relayUrl}));

      final result = await storage.query(
        RequestFilter(ids: {testNote1.id}).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );

      // Should get only one copy
      expect(result.where((e) => e.id == testNote1.id), hasLength(1));
    });
  });

  group('Isolate boundary', () {
    test('throws IsolateException for invalid and operator', () async {
      final request = RequestFilter(
        kinds: {1},
        // Closure captures testNote1 which can't cross isolate boundary
        and: (n) => {testNote1.author},
      ).toRequest();

      expect(
        () => storage.query(request, source: RemoteSource(relays: 'primary')),
        throwsA(isA<IsolateException>()),
      );
    });
  });
}

