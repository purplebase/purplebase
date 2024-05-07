import 'dart:async';

import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';

Future<void> main() async {
  final container = ProviderContainer();
  final notifier = container.read(relayMessageNotifierProvider.notifier);
  notifier.initialize(['wss://relay.nostr.band', 'wss://relay.zap.store']);

  final fms = await notifier.query(RelayRequest(kinds: {1}, limit: 2));
  print(fms);
  await notifier.dispose();
}

void main2() {
  final e = BaseEvent.partial(content: 'blah')
      .sign('deef3563ddbf74e62b2e8e5e44b25b8d63fb05e29a991f7e39cff56aa3ce82b8');
  print(e.isValid);
  print(e);
}
