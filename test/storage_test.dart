import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Future<void> main() async {
  late ProviderContainer container;
  late StorageNotifier storage;
  final signer = DummySigner();

  setUpAll(() async {
    container = ProviderContainer(
      overrides: [
        storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new),
      ],
    );
    final config = StorageConfiguration(
      databasePath: 'storage.db',
      skipVerification: true,
      relayGroups: {
        'test': {'wss://test.com'},
      },
      defaultRelayGroup: 'test',
    );
    await container.read(initializationProvider(config).future);
    storage = container.read(storageNotifierProvider.notifier);
  });

  tearDown(() async {
    await storage.clear();
  });

  tearDownAll(() async {
    storage.dispose();
    storage.obliterateDatabase();
  });

  test('query by tag', () async {
    final pn1 = PartialNote('yo');
    pn1.internal.addTagValue('bar', 'baz');
    final n1 = await pn1.signWith(signer);

    final n2 = await PartialNote(
      'yope',
      tags: {'nostr', 'test'},
    ).signWith(signer);
    await storage.save({n1, n2});

    final r1 = storage.querySync(
      RequestFilter(
        tags: {
          '#t': {'nostr', 'test'},
        },
      ),
    );
    expect(r1, unorderedEquals([n2]));

    final r1b = storage.querySync(
      RequestFilter(
        tags: {
          '#t': {'nostr'},
        },
      ),
    );
    expect(r1b, unorderedEquals([n2]));

    final r2 = storage.querySync(
      RequestFilter(
        tags: {
          'bar': {'baz'},
        },
      ),
    );
    // Empty as multiple-character tags are not indexed
    expect(r2, isEmpty);

    final r3 = storage.querySync(RequestFilter(ids: {n1.id}));
    expect(r3, [n1]);
  });

  test('query by ids', () async {
    // Create three different notes
    final n1 = await PartialNote('note 1').signWith(signer);
    final n2 = await PartialNote('note 2').signWith(signer);
    final n3 = await PartialNote('note 3').signWith(signer);

    // Save all notes to storage
    await storage.save({n1, n2, n3});

    // Query for a single ID
    final r1 = storage.querySync(RequestFilter(ids: {n1.id}));
    expect(r1, [n1]);

    // Query for multiple IDs
    final r2 = storage.querySync(RequestFilter(ids: {n1.id, n3.id}));
    expect(r2, unorderedEquals([n1, n3]));

    // Query for non-existent ID
    final r3 = storage.querySync(RequestFilter(ids: {'nonexistent_id'}));
    expect(r3, isEmpty);

    // Query for mixed existing and non-existent IDs
    final r4 = storage.querySync(RequestFilter(ids: {n2.id, 'nonexistent_id'}));
    expect(r4, [n2]);
  });

  test('massive query by tag', () async {
    final amount = 3000;
    final futures = List.generate(
      amount,
      (i) => PartialNote('note $i', tags: {'test $i'}).signWith(signer),
    );
    final notes = await Future.wait(futures);

    // Save all notes to storage
    await storage.save(notes.toSet());
    notes.shuffle();

    // final m1 = DateTime.now().millisecondsSinceEpoch;
    for (final i in List.generate(amount, (i) => i)) {
      final r1 = storage.querySync(
        RequestFilter(
          tags: {
            '#t': {'test $i'},
          },
        ),
      );
      expect(r1.map((e) => e.internal.content), contains('note $i'));
    }
    // final m2 = DateTime.now().millisecondsSinceEpoch;
    // print(m2 - m1);
  });

  test('query by kinds', () async {
    // Create a Note (kind 1)
    final note = await PartialNote('regular note').signWith(signer);

    // Create a DirectMessage (kind 4)
    final dm = await PartialDirectMessage(
      content: 'hello there',
      receiver:
          '8f1536c05fa9c3f441f1a369b661f3cb1072f418a876d153edf3fc6eec41794c',
    ).signWith(signer);

    // Save all events to storage
    await storage.save({note, dm});

    // Query for kind 1 (standard note)
    final r1 = storage.querySync(RequestFilter(kinds: {1}));
    expect(r1, [note]);

    // Query for kind 4 (direct message)
    final r2 = storage.querySync(RequestFilter(kinds: {4}));
    expect(r2, [dm]);

    // Query for multiple kinds
    final r3 = storage.querySync(RequestFilter(kinds: {1, 4}));
    expect(r3, unorderedEquals([note, dm]));

    // Query for non-existent kind
    final r4 = storage.querySync(RequestFilter(kinds: {999}));
    expect(r4, isEmpty);
  });

  test('query by authors', () async {
    // Get the public key once and reuse it
    final pubkey = await signer.getPublicKey();

    // Create a custom signer with a different pubkey for testing
    final customPubkey =
        'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

    // Create notes from different authors
    final n1 = await PartialNote('note from default author').signWith(signer);
    // Use custom pubkey for second note
    final n2 = await PartialNote(
      'note from custom author',
    ).signWith(signer, withPubkey: customPubkey);
    final n3 = await PartialNote(
      'another note from default author',
    ).signWith(signer);

    // Save all notes to storage
    await storage.save({n1, n2, n3});

    // Query for default author
    final r1 = storage.querySync(RequestFilter(authors: {pubkey!}));
    expect(r1, unorderedEquals([n1, n3]));

    // Query for custom author
    final r2 = storage.querySync(RequestFilter(authors: {customPubkey}));
    expect(r2, [n2]);

    // Query for multiple authors
    final r3 = storage.querySync(
      RequestFilter(authors: {pubkey, customPubkey}),
    );
    expect(r3, unorderedEquals([n1, n2, n3]));

    // Query for non-existent author
    final r4 = storage.querySync(
      RequestFilter(authors: {'nonexistent_author'}),
    );
    expect(r4, isEmpty);
  });

  test('query by since and until timestamps', () async {
    // Create notes with different timestamps
    final now = DateTime.now();
    final yesterday = now.subtract(Duration(days: 1));
    final twoDaysAgo = now.subtract(Duration(days: 2));
    final lastWeek = now.subtract(Duration(days: 7));

    final n1 = await PartialNote(
      'old note',
      createdAt: lastWeek,
    ).signWith(signer);

    final pn2 = PartialNote('recent note', createdAt: yesterday);
    final n2 = await pn2.signWith(signer);

    final n3 = await PartialNote(
      'very old note',
      createdAt: twoDaysAgo,
    ).signWith(signer);

    // Save all notes to storage
    await storage.save({n1, n2, n3});

    final r1 = storage.querySync(
      RequestFilter(since: now.subtract(Duration(days: 3))),
    );
    expect(r1, [n2, n3]);

    // Query notes until yesterday (should include n1 and n3)
    final r2 = storage.querySync(RequestFilter(until: yesterday));
    expect(r2, unorderedEquals([n1, n3]));

    // Query notes within a time range (should include only n3)
    final r3 = storage.querySync(
      RequestFilter(since: lastWeek.add(Duration(days: 1)), until: yesterday),
    );
    expect(r3, [n3]);

    // Query with a future since date (should be empty)
    final r4 = storage.querySync(
      RequestFilter(since: now.add(Duration(days: 1))),
    );
    expect(r4, isEmpty);

    // Query with a past until date (should be empty)
    final r5 = storage.querySync(
      RequestFilter(until: lastWeek.subtract(Duration(days: 1))),
    );
    expect(r5, isEmpty);
  });

  test('ultimate comprehensive query', () async {
    // Get the default public key
    final pubkey = await signer.getPublicKey();

    // Create a custom pubkey
    final customPubkey =
        'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

    // Define test timestamps
    final now = DateTime.now();
    final yesterday = now.subtract(Duration(days: 1));
    final threeDaysAgo = now.subtract(Duration(days: 3));
    final fiveDaysAgo = now.subtract(Duration(days: 5));
    final lastWeek = now.subtract(Duration(days: 7));

    // Create test notes

    // Note 1: Default author with 'announcement' tag (recent)
    final pn1 = PartialNote(
      'note 1',
      createdAt: yesterday,
      tags: {'announcement'},
    );
    final n1 = await pn1.signWith(signer);

    // Note 2: Custom author with 'question' tag (3 days ago)
    final pn2 = PartialNote(
      'note 2',
      createdAt: threeDaysAgo,
      tags: {'question'},
    );
    final n2 = await pn2.signWith(signer, withPubkey: customPubkey);

    // Note 3: Default author with 'archived' tag (old)
    final pn3 = PartialNote('note 3', createdAt: lastWeek, tags: {'archived'});
    final n3 = await pn3.signWith(signer);

    // Note 4: Default author with 'announcement' tag (5 days ago)
    final pn4 = PartialNote(
      'note 4',
      createdAt: fiveDaysAgo,
      tags: {'announcement'},
    );
    final n4 = await pn4.signWith(signer);

    // Create a Direct Message
    final dm = await PartialDirectMessage(
      content: 'private message',
      receiver:
          '8f1536c05fa9c3f441f1a369b661f3cb1072f418a876d153edf3fc6eec41794c',
    ).signWith(signer);

    // Save all events
    await storage.save({n1, n2, n3, n4, dm});

    // Run the comprehensive query with 'announcement' tag
    final announcementResults = storage.querySync(
      RequestFilter(
        ids: {n1.id, n2.id, n4.id}, // Include n1, n2, n4 by ID
        kinds: {1}, // Only standard notes
        authors: {pubkey!}, // Only default author
        since: now.subtract(Duration(days: 6)), // Last 6 days
        until: now, // Until now
        tags: {
          '#t': {'announcement'}, // Only notes with 'announcement' tag
        },
      ),
    );

    // Expected: Only n1 and n4 (they match all criteria)
    expect(announcementResults, unorderedEquals([n1, n4]));

    // Run a second comprehensive query with 'question' tag
    final questionResults = storage.querySync(
      RequestFilter(
        ids: {n1.id, n2.id, n4.id}, // Include n1, n2, n4 by ID
        kinds: {1}, // Only standard notes
        authors: {customPubkey}, // Only custom author
        since: now.subtract(Duration(days: 6)), // Last 6 days
        until: now, // Until now
        tags: {
          '#t': {'question'}, // Only notes with 'question' tag
        },
      ),
    );

    // Expected: Only n2 (matches all criteria)
    expect(questionResults, [n2]);

    // Full comprehensive query that should return multiple notes
    final comprehensiveResults = storage.querySync(
      RequestFilter(
        ids: {n1.id, n2.id, n4.id}, // Include n1, n2, n4 by ID
        kinds: {1}, // Only standard notes
        authors: {pubkey, customPubkey}, // Both authors
        since: now.subtract(Duration(days: 6)), // Last 6 days
        until: now, // Until now
        // Note: We're using only 'announcement' here based on our understanding
        // of how tag queries work
        tags: {
          '#t': {'announcement'},
        },
      ),
    );

    // Expected: n1 and n4 (they match all criteria)
    expect(comprehensiveResults, unorderedEquals([n1, n4]));
  });

  test('send', () async {
    final n1 = await PartialNote('yo').signWith(signer);
    await storage.save({n1});
    await storage.send(
      RequestFilter(kinds: {1}, ids: {'b', 'a', n1.id}, storageOnly: true),
    );
  });

  test('query by relay', () async {
    final n1 = await PartialNote('no relay').signWith(signer);
    final n2 = await PartialNote('yes relay').signWith(signer);
    await storage.save({n1});
    await storage.save({n2}, relayGroup: 'test');

    final r1 = storage.querySync(RequestFilter(on: 'test')).cast<Note>();
    expect(r1.map((n) => n.content), contains('yes relay'));
  });

  test('response metadata', () {
    final r1 = ResponseMetadata(subscriptionId: 'a', relayUrls: {'wss://test'});
    final r2 = ResponseMetadata(subscriptionId: 'a', relayUrls: {'wss://test'});
    expect(r1, equals(r2));
  });

  group('request notifier', () {
    test('relay request should notify with events', () async {
      final tester = container.testerFor(query(kinds: {1}));
      final n1 = await PartialNote('yo').signWith(signer);
      await storage.save({n1});

      await tester.expect(
        isA<StorageData>().having((s) => s.models, 'models', {n1}),
      );
    });
  });
}
