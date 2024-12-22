import 'dart:async';

import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const pk = 'deef3563ddbf74e62b2e8e5e44b25b8d63fb05e29a991f7e39cff56aa3ce82b8';
final signer = Bip340PrivateKeySigner(pk);

class Release extends ParameterizableReplaceableEvent<Release>
    with ReleaseMixin {
  Release.fromJson(super.map) : super.fromJson();

  // TODO: Remove
  @override
  EventConstructor<Release> get constructor => Release.fromJson;
}

mixin ReleaseMixin on EventBase {
  @override
  int get kind => 30063;

  String get releaseNotes => event.content;
}

class PartialRelease extends ParameterizableReplaceablePartialEvent<Release>
    with ReleaseMixin {
  set releaseNotes(String value) => event.content = value;
}

Future<void> main() async {
  test('general', () async {
    final container = ProviderContainer();
    // NOTE: Does not work with relay.nostr.band,
    // they do not include "error" in their NOTICE messages
    final relay = container.read(
        relayProviderFamily({'wss://relay.damus.io', 'wss://relay.primal.net'})
            .notifier);

    final r1 = RelayRequest(kinds: {1}, limit: 2);
    final r2 = RelayRequest(kinds: {6}, limit: 3);
    final k1s = await relay.queryRaw(r1);
    final k6s = await relay.queryRaw(r2);
    final k7s = await relay.queryRaw(RelayRequest(kinds: {7}, limit: 4));

    expect(k1s.length, greaterThanOrEqualTo(2));
    expect(k6s.length, greaterThanOrEqualTo(3));
    expect(k7s.length, greaterThanOrEqualTo(4));

    await relay.dispose();
  }, timeout: Timeout(Duration(seconds: 10)));

  test('zs', () async {
    final container = ProviderContainer();
    // NOTE: Does not work with relay.nostr.band,
    // they do not include "error" in their NOTICE messages
    final relay = container
        .read(relayProviderFamily({'wss://relay.zapstore.dev'}).notifier);

    final r1 = RelayRequest(kinds: {30063}, limit: 10);
    final k1s = await relay.queryRaw(r1);

    expect(k1s, hasLength(10));

    await relay.dispose();
  }, timeout: Timeout(Duration(seconds: 10)));

  test('event', () async {
    final defaultEvent = PartialApp()
      ..name = 'app'
      ..event.identifier = 'w';
    print(defaultEvent.toMap());
    // expect(defaultEvent.isValid, isFalse);

    final t = DateTime.parse('2024-07-26');
    final signedEvent = await signer.sign(PartialApp()
      ..name = 'tr'
      ..event.createdAt = t); // identifier: 's1'
    // expect(signedEvent.isValid, isTrue);
    print(signedEvent.toMap());

    final signedEvent2 = await signer.sign(PartialApp()
      ..name = 'tr'
      ..event.createdAt = t); // identifier: 's1'
    // expect(signedEvent2.isValid, isTrue);
    print(signedEvent2.toMap());
    // Test equality
    expect(signedEvent, signedEvent2);
  });

  test('app from dart', () async {
    final app = await signer.sign(PartialApp()
      ..description =
          'test app'); // identifier: 'blah'; pubkeys: {'90983aebe92bea'}

    // expect(app.isValid, isTrue);
    expect(app.kind, 32267);
    expect(app.description, 'test app');
    // expect(app.identifier, 'blah');
    // expect(app.getReplaceableEventLink(), (
    //   32267,
    //   'f36f1a2727b7ab02e3f6e99841cd2b4d9655f8cfa184bd4d68f4e4c72db8e5c1',
    //   'blah'
    // ));
    // expect(app.pubkeys, {'90983aebe92bea'});
    expect(App.fromJson(app.toMap()), app);
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
    // expect(app.isValid, isTrue);
    expect(app.event.tags,
        {'android', 'input-method', 'keyboard', 'kotlin', 'kotlin-android'});
  });

  test('publish', () async {
    // final container = ProviderContainer();
    // final prel = PartialRelease()..event.identifier = 'hello';
    final r3 = Release.fromJson({
      "id": "1bd80e5d2fd3134ab1bb8e2d98b7868b94bff8431dc083874bd5486251af0f21",
      "pubkey":
          "645681b9d067b1a362c4bee8ddff987d2466d49905c26cb8fec5e6fb73af5c84",
      "sig":
          "2291d74ac5bee27986a644d60742d8609e5a02db8e37cb44e9447b517787dae584d57f0f367eb02419d6d4489d0afd1cb4e6eb98c78d6bf4844b40cad717410e",
      "kind": 30063,
      "created_at": 1734697389,
      "content":
          "NewPokey release v0.1.3-alpha\r\n\r\n## Features\r\n\r\n<img src=\"https://image.nostr.build/6342840f0cd13ca4e23fb732f9a3d9b3b448b7914b5b427e5d48a1c3e1f337f6.jpg\" width=\"400\"/>\r\n\r\n- Notifications center\r\n- Views rearrangement\r\n\r\n## Bugs\r\n\r\n- Background service automatically recovers after fatal error\r\n\r\nhttps://github.com/KoalaSat/pokey/releases/tag/v0.1.3-alpha\r\n\r\n\r\n## What's Changed\r\n* Notifications list by @KoalaSat in https://github.com/KoalaSat/pokey/pull/65\r\n* Recover background service by @KoalaSat in https://github.com/KoalaSat/pokey/pull/6\r\n\r\n\r\n**Full Changelog**: https://github.com/KoalaSat/pokey/compare/v0.1.2-alpha...v0.1.3-alpha",
      "tags": [
        ["url", "https://github.com/KoalaSat/pokey/releases/tag/v0.1.3-alpha"],
        [
          "e",
          "d14f7e7bbc1edd13bc4d9786f2d2da8e146869e5b9d05f6048a1d07798eb4e2e"
        ],
        [
          "a",
          "32267:645681b9d067b1a362c4bee8ddff987d2466d49905c26cb8fec5e6fb73af5c84:com.koalasat.pokey"
        ],
        ["d", "com.koalasat.pokey@v0.1.3-alpha"]
      ]
    });
    print(r3.id);
    print(r3.event.identifier);

    // print(prel.event.identifier);
    // final relay = container
    //     .read(relayProviderFamily({'wss://relay.zapstore.dev'}).notifier);
    // final e = await signer.sign(PartialRelease());
    // // Should fail because pk is not authorized by relay.zapstore.dev
    // await expectLater(() => relay.publish(e), throwsException);
    // await relay.dispose();
  });

  test('typed query', () async {
    final container = ProviderContainer();
    final relay = container
        .read(relayProviderFamily({'wss://relay.zapstore.dev'}).notifier);
    final apps = await relay.query<App>(search: 'xq');
    expect(apps.first.repository, 'https://github.com/sibprogrammer/xq');
  });

  test('notifier equality', () {
    final container = ProviderContainer();
    final n1 = container
        .read(relayProviderFamily(const {'wss://relay.damus.io'}).notifier);
    final n2 = container
        .read(relayProviderFamily(const {'wss://relay.damus.io'}).notifier);
    expect(n1, n2);
  });
}
