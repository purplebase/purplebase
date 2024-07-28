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
    final notifier = container
        .read(relayMessageNotifierProvider(['wss://relay.damus.io']).notifier);
    notifier.initialize();

    final r1 = RelayRequest(kinds: {1}, limit: 2);
    final r2 = RelayRequest(kinds: {6}, limit: 3);
    final k1s = await notifier.query(r1);
    final k6s = await notifier.query(r2);
    final k7s = await notifier.query(RelayRequest(kinds: {7}, limit: 4));

    expect(k1s, hasLength(2));
    expect(k6s, hasLength(3));
    expect(k7s, hasLength(4));

    await expectLater(
        () => notifier.query(RelayRequest(ids: {'a'})), throwsException);

    await notifier.dispose();
  }, timeout: Timeout(Duration(seconds: 10)));

  test('event', () {
    final defaultEvent = BaseApp(name: 'tr');
    print(defaultEvent.toMap());
    expect(defaultEvent.isValid, isFalse);

    final t = DateTime.parse('2024-07-26');
    final signedEvent = BaseApp(name: 'tr', createdAt: t).sign(pk);
    expect(signedEvent.isValid, isTrue);
    print(signedEvent.toMap());

    final signedEvent2 = BaseApp(name: 'tr', createdAt: t).sign(pk);
    expect(signedEvent2.isValid, isTrue);
    print(signedEvent2.toMap());
    // Test equality
    expect(signedEvent, signedEvent2);
  });

  test('app from dart', () {
    final app =
        BaseApp(content: 'test app', pubkeys: {'90983aebe92bea'}).sign(pk);
    expect(app.isValid, isTrue);
    expect(app.kind, 32267);
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
    final relay = container
        .read(relayMessageNotifierProvider(['wss://relay.zap.store']).notifier);
    relay.initialize();
    final e = BaseRelease().sign(pk);
    // Should fail because pk is not authorized by relay.zap.store
    await expectLater(() => relay.publish(e), throwsException);
  });
}
