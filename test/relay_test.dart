import 'dart:async';

import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

Future<void> main() async {
  test('yo', () async {
    final container = ProviderContainer();
    final notifier = container.read(relayMessageNotifierProvider.notifier);
    notifier.initialize(['wss://relay.nostr.band']);

    final r1 = RelayRequest(kinds: {1}, limit: 2);
    final r2 = RelayRequest(kinds: {6}, limit: 3);
    final k1s = await notifier.query(r1);
    final k6s = await notifier.query(r2);
    final k7s = await notifier.query(RelayRequest(kinds: {7}, limit: 4));
    expect(k1s, hasLength(2));
    expect(k6s, hasLength(3));
    expect(k7s, hasLength(4));
    await notifier.dispose();
  }, timeout: Timeout(Duration(seconds: 10)));
}

void main2() {
  final e = BaseEvent.partial(content: 'blah')
      .sign('deef3563ddbf74e62b2e8e5e44b25b8d63fb05e29a991f7e39cff56aa3ce82b8');
  print(e.isValid);
  print(e);
}
