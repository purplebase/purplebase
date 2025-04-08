import 'dart:async';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:test/test.dart';

class WebSocketPoolTester {
  final WebSocketPool notifier;

  final _disposeFns = [];
  var completer = Completer();
  var initial = true;

  WebSocketPoolTester(this.notifier, {bool fireImmediately = false}) {
    final dispose = notifier.addListener((state) {
      // print('yo $state');
      if (fireImmediately && initial) {
        Future.microtask(() {
          completer.complete(state);
          completer = Completer();
          initial = false;
        });
      } else {
        completer.complete(state);
        completer = Completer();
      }
    }, fireImmediately: fireImmediately);
    _disposeFns.add(dispose);
  }

  Future<dynamic> expect(Matcher m) async {
    return expectLater(completer.future, completion(m));
  }

  // Future<dynamic> expectModels(Matcher m) async {
  //   return expect(isA<StorageData>().having((s) => s.models, 'models', m));
  // }

  dispose() {
    for (final fn in _disposeFns) {
      fn.call();
    }
  }
}
