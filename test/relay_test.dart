import 'dart:async';

import 'package:models/models.dart';

const pk = 'deef3563ddbf74e62b2e8e5e44b25b8d63fb05e29a991f7e39cff56aa3ce82b8';
final signer = Bip340PrivateKeySigner(pk);

Future<void> main() async {
  // test('general', () async {
  //   final container = ProviderContainer();
  //   // NOTE: Does not work with relay.nostr.band,
  //   // they do not include "error" in their NOTICE messages
  //   final relay = container.read(
  //       relayProviderFamily({'wss://relay.damus.io', 'wss://relay.primal.net'})
  //           .notifier);

  //   final r1 = RequestFilter(kinds: {1}, limit: 2);
  //   final r2 = RequestFilter(kinds: {6}, limit: 3);
  //   final k1s = await relay.queryRaw(r1);
  //   final k6s = await relay.queryRaw(r2);
  //   final k7s = await relay.queryRaw(RequestFilter(kinds: {7}, limit: 4));

  //   expect(k1s.length, greaterThanOrEqualTo(2));
  //   expect(k6s.length, greaterThanOrEqualTo(3));
  //   expect(k7s.length, greaterThanOrEqualTo(4));

  //   await relay.dispose();
  // }, timeout: Timeout(Duration(seconds: 10)));

  // test('stream', () async {
  //   final container = ProviderContainer();

  //   final relay =
  //       container.read(relayProviderFamily({'wss://relay.damus.io'}).notifier);
  //   final tester = RelayMessageNotifierTester(relay);
  //   final r1 = RequestFilter(kinds: {1}, limit: 2);
  //   relay.send(r1);

  //   await tester.expect(isA<EventRelayMessage>()
  //       .having((s) => s.subscriptionId, 'sub', equals(r1.subscriptionId)));
  //   await tester.expect(isA<EventRelayMessage>());
  //   await tester.expect(isA<EoseRelayMessage>());
  //   tester.dispose();
  // }, timeout: Timeout(Duration(seconds: 10)));

  // test('zs', () async {
  //   final container = ProviderContainer();
  //   // NOTE: Does not work with relay.nostr.band,
  //   // they do not include "error" in their NOTICE messages
  //   final relay = container
  //       .read(relayProviderFamily({'wss://relay.zapstore.dev'}).notifier);

  //   final r1 = RequestFilter(kinds: {30063}, limit: 10);
  //   final k1s = await relay.queryRaw(r1);

  //   expect(k1s, hasLength(10));

  //   await relay.dispose();
  // }, timeout: Timeout(Duration(seconds: 10)));

  // test('publish', () async {
  //   final container = ProviderContainer();
  //   final release = PartialRelease()..identifier = 'test';
  //   final relay = container
  //       .read(relayProviderFamily({'wss://relay.zapstore.dev'}).notifier);
  //   final e = await signer.sign(release);
  //   print(e.toMap());
  //   // Should fail because pk is not authorized by relay.zapstore.dev
  //   // TODO RESTORE
  //   // await expectLater(() => relay.publish(e), throwsException);
  //   await relay.dispose();
  // });

  // test('typed query', () async {
  //   final container = ProviderContainer();
  //   final relay = container
  //       .read(relayProviderFamily({'wss://relay.zapstore.dev'}).notifier);
  //   final apps = await relay.query<App>(search: 'xq');
  //   print(apps.first.toMap());
  //   expect(apps.first.repository, 'https://github.com/sibprogrammer/xq');
  // });

  // test('notifier equality', () {
  //   final container = ProviderContainer();
  //   final n1 = container
  //       .read(relayProviderFamily(const {'wss://relay.damus.io'}).notifier);
  //   final n2 = container
  //       .read(relayProviderFamily(const {'wss://relay.damus.io'}).notifier);
  //   expect(n1, n2);
  // });
}

// class RelayMessageNotifierTester {
//   final RelayMessageNotifier notifier;

//   final _disposeFns = [];
//   var completer = Completer();
//   var initial = true;

//   RelayMessageNotifierTester(this.notifier, {bool fireImmediately = false}) {
//     final dispose = notifier.addListener((_) {
//       // print('received: $_');
//       if (fireImmediately && initial) {
//         Future.microtask(() {
//           completer.complete(_);
//           completer = Completer();
//           initial = false;
//         });
//       } else {
//         completer.complete(_);
//         completer = Completer();
//       }
//     }, fireImmediately: fireImmediately);
//     _disposeFns.add(dispose);
//   }

//   Future<void> expect(Matcher m) async {
//     return expectLater(completer.future, completion(m));
//   }

//   dispose() {
//     for (final fn in _disposeFns) {
//       fn.call();
//     }
//   }
// }
