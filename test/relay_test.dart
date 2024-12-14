import 'dart:async';

import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

Future<void> main() async {
  final pk = 'deef3563ddbf74e62b2e8e5e44b25b8d63fb05e29a991f7e39cff56aa3ce82b8';

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
    final relay =
        container.read(relayProviderFamily({'wss://relay.zap.store'}).notifier);

    final r1 = RelayRequest(kinds: {30063}, limit: 10);
    final k1s = await relay.queryRaw(r1);

    expect(k1s, hasLength(10));

    await relay.dispose();
  }, timeout: Timeout(Duration(seconds: 10)));

  test('event', () {
    final defaultEvent = BaseApp(name: 'tr', identifier: 'default');
    print(defaultEvent.toMap());
    expect(defaultEvent.isValid, isFalse);

    final t = DateTime.parse('2024-07-26');
    final signedEvent =
        BaseApp(name: 'tr', createdAt: t, identifier: 's1').sign(pk);
    expect(signedEvent.isValid, isTrue);
    print(signedEvent.toMap());

    final signedEvent2 =
        BaseApp(name: 'tr', createdAt: t, identifier: 's1').sign(pk);
    expect(signedEvent2.isValid, isTrue);
    print(signedEvent2.toMap());
    // Test equality
    expect(signedEvent, signedEvent2);
  });

  test('app from dart', () {
    final app = BaseApp(
            content: 'test app',
            pubkeys: {'90983aebe92bea'},
            identifier: 'blah')
        .sign(pk);
    expect(app.isValid, isTrue);
    expect(app.kind, 32267);
    expect(app.identifier, 'blah');
    expect(app.getReplaceableEventLink(), (
      32267,
      'f36f1a2727b7ab02e3f6e99841cd2b4d9655f8cfa184bd4d68f4e4c72db8e5c1',
      'blah'
    ));
    expect(app.pubkeys, {'90983aebe92bea'});
    expect(BaseApp.fromJson(app.toMap()), app);
  });

  test('app from json', () {
    final app = BaseApp.fromJson({
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
    expect(app.isValid, isTrue);
    expect(app.tags,
        {'android', 'input-method', 'keyboard', 'kotlin', 'kotlin-android'});
  });

  test('publish', () async {
    final container = ProviderContainer();
    final relay =
        container.read(relayProviderFamily({'ws://localhost:3000'}).notifier);
    final e = BaseRelease().sign(pk);
    // Should fail because pk is not authorized by relay.zap.store
    await expectLater(() => relay.publish(e), throwsException);
    await relay.dispose();
  });

  test('typed query', () async {
    final container = ProviderContainer();
    final relay =
        container.read(relayProviderFamily({'wss://relay.zap.store'}).notifier);
    final apps = await relay.query<BaseApp>(search: 'xq');
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
