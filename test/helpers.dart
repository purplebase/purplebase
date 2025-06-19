import 'dart:async';
import 'dart:io';

import 'package:models/models.dart';
import 'package:path/path.dart' as path;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final refProvider = Provider((ref) => ref);

class StateNotifierTester {
  final StateNotifier notifier;

  final _disposeFns = [];
  var completer = Completer();
  var initial = true;

  StateNotifierTester(this.notifier, {bool fireImmediately = false}) {
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

extension ProviderContainerExt on ProviderContainer {
  StateNotifierTester testerFor(
    AutoDisposeStateNotifierProvider provider, {
    bool fireImmediately = false,
  }) {
    // Keep the provider alive during the test
    listen(provider, (_, __) {}).read();

    return StateNotifierTester(
      read(provider.notifier),
      fireImmediately: fireImmediately,
    );
  }
}

extension StorageExt on StorageNotifier {
  void obliterateDatabase() {
    if (config.databasePath == null) return;
    // Obliterate database
    Directory.current.listSync().forEach((entity) {
      if (entity is File &&
          entity.path.startsWith(
            path.join(Directory.current.path, config.databasePath),
          )) {
        entity.deleteSync();
      }
    });
  }
}
