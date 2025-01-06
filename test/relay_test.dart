import 'dart:async';

// Hiding Release from purplebase, and using a local release definition
// in order to test defining models outside of the library
import 'package:purplebase/purplebase.dart' hide Release, PartialRelease;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'release.dart';

const pk = 'deef3563ddbf74e62b2e8e5e44b25b8d63fb05e29a991f7e39cff56aa3ce82b8';
final signer = Bip340PrivateKeySigner(pk);

//

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

  test('publish', () async {
    final container = ProviderContainer();
    Event.types['Release'] = (kind: 30063, constructor: Release.fromJson);
    final release = PartialRelease()..identifier = 'test';
    final relay = container
        .read(relayProviderFamily({'wss://relay.zapstore.dev'}).notifier);
    final e = await signer.sign(release);
    print(e.toMap());
    // Should fail because pk is not authorized by relay.zapstore.dev
    await expectLater(() => relay.publish(e), throwsException);
    await relay.dispose();
  });

  test('typed query', () async {
    final container = ProviderContainer();
    final relay = container
        .read(relayProviderFamily({'wss://relay.zapstore.dev'}).notifier);
    final apps = await relay.query<App>(search: 'xq');
    print(apps.first.toMap());
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
