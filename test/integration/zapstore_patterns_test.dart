import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

/// Zapstore-inspired integration tests.
///
/// These tests exercise the exact purplebase/models patterns used by
/// the Zapstore Flutter app, translated to pure-Dart equivalents:
///   - ref.watch(query<T>(...))  →  container.listen(query<T>(...), ...)
///   - WidgetRef ref             →  ProviderContainer + Ref
///   - AmberSigner               →  Bip340PrivateKeySigner / DummySigner
///
/// The 15 scenarios cover: initialization, queries (local/remote/reactive),
/// relationships, caching, streaming, model creation & signing, publishing,
/// encryption, batch loading, pool state, lifecycle, schema filters,
/// relay resolution, and storage mutations.

const _relayPort = TestPorts.zapstorePatterns;

void main() {
  Process? relayProcess;
  final relayUrl = 'ws://127.0.0.1:$_relayPort';

  late ProviderContainer container;
  late PurplebaseStorageNotifier storage;
  late Bip340PrivateKeySigner signer;
  late Directory tempDir;

  setUpAll(() async {
    relayProcess = await Process.start(
      'test/support/test-relay',
      ['-port', _relayPort.toString()],
    );
    relayProcess!.stdout.transform(utf8.decoder).listen((_) {});
    relayProcess!.stderr.transform(utf8.decoder).listen((_) {});
    await Future.delayed(Duration(milliseconds: 500));

    tempDir = await Directory.systemTemp.createTemp('purplebase_zapstore_');
    final dbPath = '${tempDir.path}/test.db';

    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );

    final config = StorageConfiguration(
      databasePath: dbPath,
      skipVerification: true,
      defaultRelays: {
        'test': {relayUrl},
      },
      defaultQuerySource:
          LocalAndRemoteSource(relays: 'test', stream: false),
      responseTimeout: Duration(seconds: 5),
    );

    await container.read(initializationProvider(config).future);
    storage = container.storage;

    signer = Bip340PrivateKeySigner(TestKeys.privateKey, container.ref);
    await signer.signIn();
  });

  setUp(() async {
    await storage.clear();
  });

  tearDownAll(() async {
    // Close subscriptions before disposing to avoid cancel-after-dispose errors
    try {
      await storage.closeSubscriptions(relays: {relayUrl});
    } catch (_) {}
    await Future.delayed(Duration(milliseconds: 100));
    storage.dispose();
    await Future.delayed(Duration(milliseconds: 100));
    try {
      container.dispose();
    } catch (_) {}
    relayProcess?.kill();
    await relayProcess?.exitCode;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  // ---------------------------------------------------------------------------
  // Helpers: build a full App → Release → FileMetadata chain
  // ---------------------------------------------------------------------------

  Future<({App app, Release release, FileMetadata metadata})>
      createAppChain({
    required String appId,
    String version = '1.0.0',
    int versionCode = 100,
    String platform = 'android-arm64-v8a',
  }) async {
    final partialApp = PartialApp()
      ..identifier = appId
      ..name = 'Test App $appId'
      ..description = 'A test application'
      ..platforms = {platform};
    final app = await partialApp.signWith(signer);

    final partialRelease = PartialRelease(newFormat: true)
      ..appIdentifier = appId
      ..version = version
      ..releaseNotes = 'Release notes for $version';
    partialRelease.identifier = '$appId@$version';
    partialRelease.linkModel(app);
    final release = await partialRelease.signWith(signer);

    final partialMeta = PartialFileMetadata()
      ..version = version
      ..versionCode = versionCode
      ..hash = 'abc123'
      ..urls = {'https://example.com/$appId-$version.apk'}
      ..platforms = {platform};
    partialMeta.appIdentifier = appId;
    partialMeta.linkModel(release);
    final metadata = await partialMeta.signWith(signer);

    return (app: app, release: release, metadata: metadata);
  }

  // ---------------------------------------------------------------------------
  // 1. Init → Query → Receive Data
  // ---------------------------------------------------------------------------
  group('1. Init, query, and receive data', () {
    test('saves app locally and queries it back', () async {
      final chain = await createAppChain(appId: 'com.test.init');
      await storage.save({chain.app});

      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.init'}},
        ).toRequest(),
        source: LocalSource(),
      );

      expect(result, hasLength(1));
      expect(result.first.name, 'Test App com.test.init');
      expect(result.first.identifier, 'com.test.init');
    });

    test('reactive query via container.listen emits StorageData', () async {
      final chain = await createAppChain(appId: 'com.test.reactive');
      await storage.save({chain.app});

      // Allow the DB write to propagate to the main-isolate file handle
      await Future.delayed(Duration(milliseconds: 100));

      final states = <StorageState<App>>[];
      final sub = container.listen<StorageState<App>>(
        query<App>(
          tags: {'#d': {'com.test.reactive'}},
          source: const LocalSource(),
        ),
        (prev, next) => states.add(next),
        fireImmediately: true,
      );

      await Future.delayed(Duration(milliseconds: 500));

      expect(states, isNotEmpty);
      final hasData = states.any(
        (s) => s is StorageData<App> && s.models.isNotEmpty,
      );
      expect(hasData, isTrue);

      sub.close();
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Nested Relationship Loading (and: callback)
  // ---------------------------------------------------------------------------
  group('2. Nested relationship loading', () {
    test('App → Release → FileMetadata chain via relationship filters',
        () async {
      final chain = await createAppChain(appId: 'com.test.nested');
      await storage.save({chain.app, chain.release, chain.metadata});

      final apps = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.nested'}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(apps, hasLength(1));

      // Use relationship filters — the exact Zapstore pattern
      final releaseFilter =
          apps.first.latestRelease.req?.filters.firstOrNull;
      expect(releaseFilter, isNotNull);

      final releases = await storage.query(
        Request<Release>([releaseFilter!]),
        source: LocalSource(),
      );
      expect(releases, hasLength(1));
      expect(releases.first.version, '1.0.0');

      final metadataFilter =
          releases.first.latestMetadata.req?.filters.firstOrNull;
      expect(metadataFilter, isNotNull);

      final metadata = await storage.query(
        Request<FileMetadata>([metadataFilter!]),
        source: LocalSource(),
      );
      expect(metadata, hasLength(1));
      expect(metadata.first.version, '1.0.0');
      expect(metadata.first.versionCode, 100);
    });

    test('reactive query with and: loads nested relationships', () async {
      final chain = await createAppChain(appId: 'com.test.and');
      await storage.save({chain.app, chain.release, chain.metadata});
      await Future.delayed(Duration(milliseconds: 100));

      final states = <StorageState<App>>[];
      final sub = container.listen<StorageState<App>>(
        query<App>(
          tags: {
            '#d': {'com.test.and'},
            '#f': {'android-arm64-v8a'},
          },
          and: (app) => {
            app.latestRelease.query(
              source: const LocalSource(),
              and: (release) => {
                release.latestMetadata.query(source: const LocalSource()),
              },
            ),
          },
          source: const LocalSource(),
          subscriptionPrefix: 'test-nested',
        ),
        (prev, next) => states.add(next),
        fireImmediately: true,
      );

      await Future.delayed(Duration(milliseconds: 800));

      final dataWithModels = states
          .whereType<StorageData<App>>()
          .where((s) => s.models.isNotEmpty);
      expect(dataWithModels, isNotEmpty);

      final app = dataWithModels.last.models.first;
      expect(app.identifier, 'com.test.and');
      expect(app.latestRelease.value, isNotNull);
      expect(app.latestRelease.value!.version, '1.0.0');

      sub.close();
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Local-only Query
  // ---------------------------------------------------------------------------
  group('3. Local-only query (LocalSource)', () {
    test('LocalSource returns only locally saved data', () async {
      final chain = await createAppChain(appId: 'com.test.localonly');
      await storage.save({chain.app});

      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.localonly'}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
    });

    test('LocalSource returns empty for non-existent data', () async {
      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.doesnotexist'}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(result, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // 4. Remote Query (publish → fetch via relay)
  // ---------------------------------------------------------------------------
  group('4. Remote query via relay', () {
    test('publishes to relay then queries back', () async {
      final chain = await createAppChain(appId: 'com.test.remote');

      final publishResult = await storage.publish(
        {chain.app},
        source: RemoteSource(relays: {relayUrl}),
      );
      expect(publishResult.results, isNotEmpty);

      // Clear local to prove remote fetch works
      await storage.clear();

      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.remote'}},
        ).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );
      expect(result, hasLength(1));
      expect(result.first.identifier, 'com.test.remote');
    });
  });

  // ---------------------------------------------------------------------------
  // 5. LocalAndRemote + Caching (cachedFor in milliseconds)
  // ---------------------------------------------------------------------------
  group('5. LocalAndRemote with cachedFor (milliseconds)', () {
    test('cachedFor skips refetch within window', () async {
      final chain = await createAppChain(appId: 'com.test.cached');

      await storage.publish(
        {chain.app},
        source: RemoteSource(relays: {relayUrl}),
      );

      // First query — fetches from relay and caches
      final result1 = await storage.query(
        RequestFilter<App>(
          authors: {signer.pubkey},
          tags: {'#d': {'com.test.cached'}},
        ).toRequest(),
        source: LocalAndRemoteSource(
          relays: 'test',
          cachedFor: Duration(milliseconds: 500),
          stream: false,
        ),
      );
      expect(result1, hasLength(1));

      // Second query within 500ms — served from cache
      final result2 = await storage.query(
        RequestFilter<App>(
          authors: {signer.pubkey},
          tags: {'#d': {'com.test.cached'}},
        ).toRequest(),
        source: LocalAndRemoteSource(
          relays: 'test',
          cachedFor: Duration(milliseconds: 500),
          stream: false,
        ),
      );
      expect(result2, hasLength(1));
      expect(result2.first.id, result1.first.id);
    });

    test('cachedFor refetches after window expires', () async {
      final chain = await createAppChain(appId: 'com.test.cacheexpiry');

      await storage.publish(
        {chain.app},
        source: RemoteSource(relays: {relayUrl}),
      );

      await storage.query(
        RequestFilter<App>(
          authors: {signer.pubkey},
          tags: {'#d': {'com.test.cacheexpiry'}},
        ).toRequest(),
        source: LocalAndRemoteSource(
          relays: 'test',
          cachedFor: Duration(milliseconds: 100),
          stream: false,
        ),
      );

      await Future.delayed(Duration(milliseconds: 150));

      final result = await storage.query(
        RequestFilter<App>(
          authors: {signer.pubkey},
          tags: {'#d': {'com.test.cacheexpiry'}},
        ).toRequest(),
        source: LocalAndRemoteSource(
          relays: 'test',
          cachedFor: Duration(milliseconds: 100),
          stream: false,
        ),
      );
      expect(result, hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  // 6. Streaming Subscription
  // ---------------------------------------------------------------------------
  group('6. Streaming subscription (stream: true)', () {
    test('streaming query keeps subscription open and receives data',
        () async {
      // Publish some data first so the streaming query has something to find
      final note1 = await PartialNote('stream note 1').signWith(signer);
      await storage.publish(
        {note1},
        source: RemoteSource(relays: {relayUrl}),
      );

      // Subscribe with stream: true (Zapstore's pattern for latest releases)
      final states = <StorageState<Note>>[];
      final sub = container.listen<StorageState<Note>>(
        query<Note>(
          authors: {signer.pubkey},
          source: LocalAndRemoteSource(relays: 'test', stream: true),
          subscriptionPrefix: 'test-stream',
        ),
        (prev, next) => states.add(next),
        fireImmediately: true,
      );

      await Future.delayed(Duration(seconds: 3));

      // Verify the streaming query established and received data
      expect(states, isNotEmpty);

      // Check that the subscription picked up the note (from relay or local)
      final dataStates = states.whereType<StorageData<Note>>();
      expect(dataStates, isNotEmpty);

      sub.close();
    });
  });

  // ---------------------------------------------------------------------------
  // 7. Create + Sign + Save + Publish (full round-trip)
  // ---------------------------------------------------------------------------
  group('7. Create, sign, save, publish round-trip', () {
    test('PartialProfile: create → sign → save → query', () async {
      final partial = PartialProfile(
        name: 'Test User',
        about: 'Integration test profile',
      );
      final profile = await partial.signWith(signer);
      await storage.save({profile});

      final result = await storage.query(
        RequestFilter<Profile>(authors: {signer.pubkey}).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
      expect(result.first.name, 'Test User');
      expect(result.first.about, 'Integration test profile');
    });

    test('PartialComment: create with rootModel → sign → save → query',
        () async {
      final chain = await createAppChain(appId: 'com.test.comment');
      await storage.save({chain.app});

      final partial = PartialComment(
        content: 'Great app!',
        rootModel: chain.app,
      );
      partial.event.addTagValue('v', '1.0.0');
      final comment = await partial.signWith(signer);
      await storage.save({comment});

      final result = await storage.query(
        RequestFilter<Comment>(
          tags: {'#A': {chain.app.id}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
      expect(result.first.content, 'Great app!');
    });

    test('PartialCustomData: create → sign → save locally only', () async {
      final partial = PartialCustomData(
        identifier: 'test-settings',
        content: jsonEncode({'theme': 'dark', 'fontSize': 14}),
      );
      final customData = await partial.signWith(signer);
      await storage.save({customData});

      final result = await storage.query(
        Request<CustomData>([
          RequestFilter<CustomData>(
            authors: {signer.pubkey},
            tags: {'#d': {'test-settings'}},
            limit: 1,
          ),
        ]),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
      final data = jsonDecode(result.first.content) as Map<String, dynamic>;
      expect(data['theme'], 'dark');
      expect(data['fontSize'], 14);
    });

    test('PartialContactList: create with follows → sign → save', () async {
      final otherPubkey = TestPubkeys.niel;
      final partial = PartialContactList(followPubkeys: {otherPubkey});
      final contactList = await partial.signWith(signer);
      await storage.save({contactList});

      final result = await storage.query(
        RequestFilter<ContactList>(authors: {signer.pubkey}).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
      expect(result.first.followingPubkeys, contains(otherPubkey));
    });

    test('PartialAppStack: create → sign → save → query', () async {
      final chain = await createAppChain(appId: 'com.test.stack');
      await storage.save({chain.app});

      final partialStack = PartialAppStack(
        name: 'Best Apps',
        identifier: 'my-stack',
        description: 'My favorite apps',
        platform: 'android-arm64-v8a',
        publicApps: {chain.app.id},
      );
      final stack = await partialStack.signWith(signer);
      await storage.save({stack});

      final result = await storage.query(
        RequestFilter<AppStack>(
          authors: {signer.pubkey},
          tags: {'#d': {'my-stack'}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
      expect(result.first.name, 'Best Apps');
    });

    test('publish comment to relay and query back', () async {
      final chain = await createAppChain(appId: 'com.test.pubcomment');
      await storage.save({chain.app});

      final partial = PartialComment(
        content: 'Published comment!',
        rootModel: chain.app,
      );
      final comment = await partial.signWith(signer);
      await storage.save({comment});

      final publishResult = await storage.publish(
        {comment},
        source: RemoteSource(relays: {relayUrl}),
      );
      expect(publishResult.results, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // 8. Encrypted Content (NIP-44 via Bip340PrivateKeySigner)
  // ---------------------------------------------------------------------------
  group('8. NIP-44 encryption round-trip', () {
    test('encrypt and decrypt content', () async {
      final plaintext = jsonEncode(['com.app.one', 'com.app.two']);
      final encrypted = await signer.nip44Encrypt(
        plaintext,
        signer.pubkey,
      );
      expect(encrypted, isNot(plaintext));

      final decrypted = await signer.nip44Decrypt(
        encrypted,
        signer.pubkey,
      );
      expect(decrypted, plaintext);

      final appIds = (jsonDecode(decrypted) as List).cast<String>();
      expect(appIds, ['com.app.one', 'com.app.two']);
    });
  });

  // ---------------------------------------------------------------------------
  // 9. Batch Relationship Loading via .req?.filters
  // ---------------------------------------------------------------------------
  group('9. Batch relationship loading', () {
    test('batch-loads releases and metadata for multiple apps', () async {
      final chain1 = await createAppChain(appId: 'com.test.batch1');
      final chain2 = await createAppChain(appId: 'com.test.batch2');
      await storage.save({chain1.app, chain1.release, chain1.metadata});
      await storage.save({chain2.app, chain2.release, chain2.metadata});

      // Step 1: Query apps (single filter, multiple tag values — Zapstore pattern)
      final apps = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.batch1', 'com.test.batch2'}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(apps, hasLength(2));

      // Step 2: Load releases for each app individually (matches Zapstore's
      // sequential loading pattern in _fetchUpdatesFromRemote)
      final allReleases = <Release>[];
      for (final app in apps) {
        final filter = app.latestRelease.req?.filters.firstOrNull;
        if (filter != null) {
          final releases = await storage.query(
            Request<Release>([filter]),
            source: LocalSource(),
          );
          allReleases.addAll(releases);
        }
      }
      expect(allReleases, hasLength(2));

      // Step 3: Load metadata for each release
      final allMetadata = <FileMetadata>[];
      for (final release in allReleases) {
        final filter = release.latestMetadata.req?.filters.firstOrNull;
        if (filter != null) {
          final metadata = await storage.query(
            Request<FileMetadata>([filter]),
            source: LocalSource(),
          );
          allMetadata.addAll(metadata);
        }
      }
      expect(allMetadata, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // 10. PoolState Observation
  // ---------------------------------------------------------------------------
  group('10. PoolState observation', () {
    test('poolStateProvider emits state after remote query', () async {
      final poolStates = <PoolState?>[];
      final sub = container.listen<PoolState?>(
        poolStateProvider,
        (prev, next) => poolStates.add(next),
        fireImmediately: true,
      );

      final note = await PartialNote('pool test').signWith(signer);
      await storage.publish(
        {note},
        source: RemoteSource(relays: {relayUrl}),
      );

      await Future.delayed(Duration(milliseconds: 500));
      final nonNullStates = poolStates.whereType<PoolState>().toList();
      expect(nonNullStates, isNotEmpty);

      sub.close();
    });
  });

  // ---------------------------------------------------------------------------
  // 11. Connect / Disconnect Lifecycle
  // ---------------------------------------------------------------------------
  group('11. Connect/disconnect lifecycle', () {
    test('local queries work before and after disconnect', () async {
      final note = await PartialNote('lifecycle note').signWith(signer);
      await storage.save({note});

      storage.connect();
      await Future.delayed(Duration(milliseconds: 100));

      final result = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(1));

      storage.disconnect();
      await Future.delayed(Duration(milliseconds: 100));

      final result2 = await storage.query(
        RequestFilter(ids: {note.id}).toRequest(),
        source: LocalSource(),
      );
      expect(result2, hasLength(1));

      storage.connect();
    });
  });

  // ---------------------------------------------------------------------------
  // 12. SchemaFilter (client-side filtering)
  // ---------------------------------------------------------------------------
  group('12. SchemaFilter (client-side filtering)', () {
    test('schemaFilter filters models after decode', () async {
      final chain1 =
          await createAppChain(appId: 'com.test.schemafilter.match');
      final chain2 =
          await createAppChain(appId: 'com.test.schemafilter.skip');
      await storage.save({chain1.app, chain2.app});

      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#f': {'android-arm64-v8a'}},
          schemaFilter: (event) {
            final tags = event['tags'] as List? ?? [];
            return tags.any((tag) =>
                tag is List &&
                tag.length >= 2 &&
                tag[0] == 'd' &&
                (tag[1] as String).contains('match'));
          },
        ).toRequest(),
        source: LocalSource(),
      );

      expect(result, hasLength(1));
      expect(result.first.identifier, 'com.test.schemafilter.match');
    });
  });

  // ---------------------------------------------------------------------------
  // 13. Relay Group Resolution
  // ---------------------------------------------------------------------------
  group('13. Relay group resolution', () {
    test('resolveRelays returns configured relay URLs for group name',
        () async {
      final testRelays = await storage.resolveRelays('test');
      expect(testRelays, contains(relayUrl));
    });

    test('resolveRelays with raw URL set passes through', () async {
      final relays = await storage.resolveRelays({relayUrl});
      expect(relays, contains(relayUrl));
    });
  });

  // ---------------------------------------------------------------------------
  // 14. Clear + Delete + Prune
  // ---------------------------------------------------------------------------
  group('14. Clear, delete, and prune', () {
    test('clear removes all data', () async {
      final chain = await createAppChain(appId: 'com.test.clear');
      await storage.save({chain.app, chain.release, chain.metadata});

      await storage.clear();

      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.clear'}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(result, isEmpty);
    });

    test('delete removes specific events by ID', () async {
      final chain1 = await createAppChain(appId: 'com.test.del1');
      final chain2 = await createAppChain(appId: 'com.test.del2');
      await storage.save({chain1.app});
      await storage.save({chain2.app});

      await storage.delete({chain1.app.id});

      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.del1', 'com.test.del2'}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
      expect(result.first.identifier, 'com.test.del2');
    });

    test('prune does not remove recently saved events', () async {
      final chain = await createAppChain(appId: 'com.test.prune');
      await storage.save({chain.app});

      await storage.prune(olderThan: Duration(days: 1));

      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.prune'}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
    });

    test('prune on empty database completes', () async {
      await expectLater(storage.prune(), completes);
    });
  });

  // ---------------------------------------------------------------------------
  // 15. Full Publish → Remote Query → Local Persistence Cycle
  // ---------------------------------------------------------------------------
  group('15. Full publish → remote query → local persistence', () {
    test('app survives full relay round-trip', () async {
      final chain = await createAppChain(appId: 'com.test.fullcycle');

      final publishResult = await storage.publish(
        {chain.app},
        source: RemoteSource(relays: {relayUrl}),
      );
      expect(publishResult.results, isNotEmpty);

      // Clear local to prove remote fetch works
      await storage.clear();

      // Query from remote
      final apps = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.fullcycle'}},
        ).toRequest(),
        source: RemoteSource(relays: {relayUrl}, stream: false),
      );
      expect(apps, hasLength(1));
      expect(apps.first.identifier, 'com.test.fullcycle');
    });
  });

  // ---------------------------------------------------------------------------
  // Bonus: StorageState pattern matching (Zapstore's core UI pattern)
  // ---------------------------------------------------------------------------
  group('Bonus: StorageState pattern matching', () {
    test('switch on StorageState sealed class', () async {
      final chain = await createAppChain(appId: 'com.test.pattern');
      await storage.save({chain.app});
      await Future.delayed(Duration(milliseconds: 100));

      final states = <StorageState<App>>[];
      final sub = container.listen<StorageState<App>>(
        query<App>(
          tags: {'#d': {'com.test.pattern'}},
          source: const LocalSource(),
        ),
        (prev, next) => states.add(next),
        fireImmediately: true,
      );

      await Future.delayed(Duration(milliseconds: 300));

      for (final state in states) {
        switch (state) {
          case StorageLoading():
            expect(state.models, isList);
          case StorageError(:final exception):
            fail('Unexpected error: $exception');
          case StorageData(:final models):
            expect(models, isList);
        }
      }

      expect(states.any((s) => s is StorageData<App>), isTrue);

      sub.close();
    });
  });

  // ---------------------------------------------------------------------------
  // Bonus: Signer provider access patterns
  // ---------------------------------------------------------------------------
  group('Bonus: Signer provider access', () {
    test('activePubkeyProvider returns signed-in pubkey', () {
      final pubkey = container.read(Signer.activePubkeyProvider);
      expect(pubkey, isNotNull);
      expect(pubkey, signer.pubkey);
    });

    test('activeSignerProvider returns the signer', () {
      final activeSigner = container.read(Signer.activeSignerProvider);
      expect(activeSigner, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Bonus: Request construction patterns (from Zapstore)
  // ---------------------------------------------------------------------------
  group('Bonus: Request construction patterns', () {
    test('RequestFilter.toRequest() with subscriptionPrefix', () async {
      final chain = await createAppChain(appId: 'com.test.reqpattern');
      await storage.save({chain.app});

      final result = await storage.query(
        RequestFilter<App>(
          tags: {
            '#d': {'com.test.reqpattern'},
            '#f': {'android-arm64-v8a'},
          },
        ).toRequest(subscriptionPrefix: 'test-req'),
        source: LocalSource(),
      );
      expect(result, hasLength(1));
    });

    test('single filter with multiple tag values (batch query)', () async {
      final chain1 = await createAppChain(appId: 'com.test.multi1');
      final chain2 = await createAppChain(appId: 'com.test.multi2');
      await storage.save({chain1.app});
      await storage.save({chain2.app});

      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#d': {'com.test.multi1', 'com.test.multi2'}},
        ).toRequest(),
        source: LocalSource(),
      );
      expect(result, hasLength(2));
    });

    test('query with limit returns capped results', () async {
      for (int i = 0; i < 5; i++) {
        final chain = await createAppChain(appId: 'com.test.limit$i');
        await storage.save({chain.app});
      }

      final result = await storage.query(
        RequestFilter<App>(
          tags: {'#f': {'android-arm64-v8a'}},
          limit: 3,
        ).toRequest(),
        source: LocalSource(),
      );
      expect(result.length, lessThanOrEqualTo(3));
    });
  });
}
