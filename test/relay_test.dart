import 'dart:async';

import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

Future<void> main() async {
  test('general', () async {
    final container = ProviderContainer();
    // NOTE: does not work with relay.nostr.band
    // which does not state "error" in their NOTICE messages
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
    final defaultEvent = BaseEvent();
    expect(defaultEvent.isValid, isFalse);

    final signedEvent = BaseEvent().sign(
        'deef3563ddbf74e62b2e8e5e44b25b8d63fb05e29a991f7e39cff56aa3ce82b8');
    expect(signedEvent.isValid, isTrue);
    print(signedEvent.toMap());
  });

  // TODO Test equality
}
