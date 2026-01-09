import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Tests for schemaFilter deletion behavior via isolate.
///
/// These tests verify that schemaFilter deletes rejected events from
/// local storage as specified in SPEC.md.
void main() {
  Process? relayProcess;
  final relayPort = TestPorts.isolateRemote + 2; // Use different port
  final relayUrl = 'ws://127.0.0.1:$relayPort';

  late ProviderContainer container;
  late StorageNotifier storage;
  late Bip340PrivateKeySigner signer;

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
      },
      defaultQuerySource: LocalAndRemoteSource(
        relays: 'primary',
        stream: false,
      ),
      responseTimeout: Duration(seconds: 5),
    );

    await container.read(initializationProvider(config).future);
    storage = container.read(storageNotifierProvider.notifier);

    signer = Bip340PrivateKeySigner(
      Utils.generateRandomHex64(),
      container.read(refProvider),
    );
    await signer.signIn();
  });

  tearDown(() async {
    await storage.clear();
  });

  tearDownAll(() async {
    storage.dispose();
    container.dispose();
    relayProcess?.kill();
    await relayProcess?.exitCode;
  });

  group('SchemaFilter deletion', () {
    test('deletes events rejected by schemaFilter from local storage', () async {
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Create events with different content lengths
      final shortNote = await PartialNote(
        'short $timestamp',
        tags: {'schema_test'},
      ).signWith(signer);

      final longNote = await PartialNote(
        'This is a much longer note content that should pass the filter $timestamp',
        tags: {'schema_test'},
      ).signWith(signer);

      // Publish both events to relay
      await storage.publish(
        {shortNote, longNote},
        source: RemoteSource(relays: 'primary'),
      );

      // Query with schemaFilter that rejects short content (< 30 chars)
      final result = await storage.query(
        RequestFilter(
          authors: {signer.pubkey},
          tags: {
            '#t': {'schema_test'},
          },
          schemaFilter: (event) {
            final content = event['content'] as String?;
            return content != null && content.length > 30;
          },
        ).toRequest(),
        source: RemoteSource(relays: 'primary', stream: false),
      );

      // Should only return the long note
      expect(result.length, equals(1));
      expect(result.first.id, equals(longNote.id));

      // Verify short note was deleted from local storage
      final localShort = await storage.query(
        RequestFilter(ids: {shortNote.id}).toRequest(),
        source: LocalSource(),
      );
      expect(localShort, isEmpty);

      // Verify long note is still in local storage
      final localLong = await storage.query(
        RequestFilter(ids: {longNote.id}).toRequest(),
        source: LocalSource(),
      );
      expect(localLong.length, equals(1));
      expect(localLong.first.id, equals(longNote.id));
    });

    test('keeps all events when no schemaFilter is provided', () async {
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final note1 = await PartialNote(
        'note one $timestamp',
        tags: {'no_filter_test'},
      ).signWith(signer);

      final note2 = await PartialNote(
        'note two $timestamp',
        tags: {'no_filter_test'},
      ).signWith(signer);

      await storage.publish(
        {note1, note2},
        source: RemoteSource(relays: 'primary'),
      );

      // Query without schemaFilter
      await storage.query(
        RequestFilter(
          authors: {signer.pubkey},
          tags: {
            '#t': {'no_filter_test'},
          },
        ).toRequest(),
        source: RemoteSource(relays: 'primary', stream: false),
      );

      // Both should be in local storage
      final local = await storage.query(
        RequestFilter(ids: {note1.id, note2.id}).toRequest(),
        source: LocalSource(),
      );
      expect(local.length, equals(2));
    });

    test('handles schemaFilter that rejects all events', () async {
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final note = await PartialNote(
        'will be rejected $timestamp',
        tags: {'reject_all_test'},
      ).signWith(signer);

      await storage.publish(
        {note},
        source: RemoteSource(relays: 'primary'),
      );

      // Query with schemaFilter that rejects everything
      final result = await storage.query(
        RequestFilter(
          authors: {signer.pubkey},
          tags: {
            '#t': {'reject_all_test'},
          },
          schemaFilter: (event) => false,
        ).toRequest(),
        source: RemoteSource(relays: 'primary', stream: false),
      );

      expect(result, isEmpty);

      // Verify event was deleted from local storage
      final local = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: LocalSource(),
      );
      expect(local, isEmpty);
    });
  });
}

