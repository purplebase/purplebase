import 'dart:async';

// Hiding Release from purplebase, and using a local release definition
// in order to test defining models outside of the library
import 'package:purplebase/purplebase.dart' hide Release, PartialRelease;
import 'package:test/test.dart';

const pk = 'deef3563ddbf74e62b2e8e5e44b25b8d63fb05e29a991f7e39cff56aa3ce82b8';
final signer = Bip340PrivateKeySigner(pk);

Future<void> main() async {
  test('event', () async {
    final defaultEvent = PartialApp()
      ..name = 'app'
      ..identifier = 'w';
    print(defaultEvent.toMap());
    // expect(defaultEvent.isValid, isFalse);

    final t = DateTime.parse('2024-07-26');
    final signedEvent = await signer.sign(PartialApp()
      ..name = 'tr'
      ..event.createdAt = t
      ..identifier = 's1');
    // expect(signedEvent.isValid, isTrue);
    print(signedEvent.toMap());

    final signedEvent2 = await signer.sign(PartialApp()
      ..name = 'tr'
      ..identifier = 's1'
      ..event.createdAt = t);
    // expect(signedEvent2.isValid, isTrue);
    print(signedEvent2.toMap());
    // Test equality
    expect(signedEvent, signedEvent2);
  });

  test('app from dart', () async {
    final partialApp = PartialApp()
      ..identifier = 'w'
      ..description = 'test app';
    final app = await signer
        .sign(partialApp); // identifier: 'blah'; pubkeys: {'90983aebe92bea'}
    // expect(app.isValid, isTrue);
    expect(app.event.kind, 32267);
    expect(app.description, 'test app');
    // expect(app.identifier, 'blah');
    // expect(app.getReplaceableEventLink(), (
    //   32267,
    //   'f36f1a2727b7ab02e3f6e99841cd2b4d9655f8cfa184bd4d68f4e4c72db8e5c1',
    //   'blah'
    // ));
    // expect(app.pubkeys, {'90983aebe92bea'});
    expect(App.fromJson(app.toMap()), app);

    // event and partial event should share a common interface
    // final apps = [partialApp, app];
    // apps.first.repository;

    // final note = await PartialNote().signWith(signer);
    // final List<EventBase> notes = [PartialNote(), note];
    // notes.first.event.content;
  });

  test('app from json', () {
    final app = App.fromJson({
      "id": "a4761befdf962fc3a27dbf940de2e8ef254722667de00ac81d67b1535efdcb2e",
      "created_at": 1717637610,
      "kind": 32267,
      "content":
          "An open-source keyboard for Android which respects your privacy. Currently in early-beta.",
      "pubkey":
          "78ce6faa72264387284e647ba6938995735ec8c7d5c5a65737e55130f026307d",
      "sig":
          "d6215c3fa475dbd4d63d2eab0ceb21defd9e1c89e5766b34fdd98925729c5edb0ac364cd19a22620701fb5d02f76ffbafdb34100d0b1ba5f5d877b1ff0003384",
      "tags": [
        ["d", "dev.patrickgold.florisboard"],
        ["name", "FlorisBoard"],
        ["repository", "https://github.com/florisboard/florisboard"],
        ["url", "https://florisboard.org"],
        ["t", "android"],
        ["t", "input-method"],
        ["t", "keyboard"],
        ["t", "kotlin"],
        ["t", "kotlin-android"],
        ["github_stars", "5518"],
        ["github_forks", "374"],
        ["license", "Apache-2.0"]
      ],
    });
    print(app.description);
    // expect(app.isValid, isTrue);
    // expect(app.event.tags,
    //     {'android', 'input-method', 'keyboard', 'kotlin', 'kotlin-android'});
  });

  test('tags', () {
    final note = PartialNote('yo hello')
      ..event.tags = [
        ['url', 'http://z'],
        ['e', '93893923', 'mention'],
        ['e', 'ab9387'],
        ['param', 'a', '1'],
        ['param', 'a', '2'],
        ['param', 'b', '3']
      ];
    print(note.toMap());
    note.event.addTag('param', {'b', '4'});
    note.event.removeTag('e');
    expect(note.event.containsTag('e'), isFalse);
    expect(note.event.getTag('url'), 'http://z');
    print(note.toMap());
  });
}
