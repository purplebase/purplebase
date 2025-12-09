import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final refProvider = Provider((ref) => ref);

/// Captures pool state changes for deterministic test synchronization.
/// Use this instead of Future.delayed() to wait for specific states.
class PoolStateCapture {
  final _states = <PoolState>[];
  final _waiters = <(bool Function(PoolState), Completer<PoolState>)>[];

  void onState(PoolState state) {
    _states.add(state);

    // Check all waiters
    final toRemove = <int>[];
    for (var i = 0; i < _waiters.length; i++) {
      final (predicate, completer) = _waiters[i];
      if (predicate(state) && !completer.isCompleted) {
        completer.complete(state);
        toRemove.add(i);
      }
    }
    // Remove completed waiters in reverse order
    for (final i in toRemove.reversed) {
      _waiters.removeAt(i);
    }
  }

  /// Wait for a state matching the predicate. Checks history first.
  Future<PoolState> waitFor(
    bool Function(PoolState) predicate, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    // Check history first
    for (final s in _states) {
      if (predicate(s)) return Future.value(s);
    }

    final completer = Completer<PoolState>();
    _waiters.add((predicate, completer));

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException('Timed out waiting for pool state', timeout);
      },
    );
  }

  /// Wait for relay to be connected
  Future<PoolState> waitForConnected(String relayUrl) {
    return waitFor((s) => s.isRelayConnected(relayUrl));
  }

  /// Wait for subscription to exist
  Future<PoolState> waitForSubscription(String subscriptionId) {
    return waitFor((s) => s.requests.containsKey(subscriptionId));
  }

  /// Wait for subscription to be removed
  Future<PoolState> waitForUnsubscribed(String subscriptionId) {
    return waitFor((s) => !s.requests.containsKey(subscriptionId));
  }

  /// Wait for EOSE on a subscription from specific relay
  Future<PoolState> waitForEose(String subscriptionId, String relayUrl) {
    return waitFor((s) {
      final req = s.requests[subscriptionId];
      return req != null && req.eoseReceived.contains(relayUrl);
    });
  }

  /// Get the last state (or null if none)
  PoolState? get lastState => _states.isEmpty ? null : _states.last;

  /// Clear state history
  void clear() {
    _states.clear();
  }
}

/// Start a test relay on the given port
Future<Process> startTestRelay(int port) async {
  final process = await Process.start('test/support/test-relay', [
    '-port',
    port.toString(),
  ]);

  // Suppress output
  process.stdout.transform(utf8.decoder).listen((_) {});
  process.stderr.transform(utf8.decoder).listen((_) {});

  // Wait for relay to be ready
  await Future.delayed(Duration(milliseconds: 500));
  return process;
}

extension TestRelayProcess on Process {
  /// Clear relay state by sending SIGUSR1 signal
  Future<void> clear() async {
    kill(ProcessSignal.sigusr1);
    // Small delay to let relay process the signal
    await Future.delayed(Duration(milliseconds: 50));
  }
}

/// Create a standard test configuration
StorageConfiguration testConfig(
  String relayUrl, {
  bool skipVerification = true,
  Duration responseTimeout = const Duration(seconds: 5),
  Duration streamingBufferWindow = const Duration(milliseconds: 100),
}) {
  return StorageConfiguration(
    skipVerification: skipVerification,
    defaultRelays: {
      'test': {relayUrl},
    },
    // Default to the test relay identifier for queries without explicit source
    defaultQuerySource: const LocalAndRemoteSource(
      relays: 'test',
      stream: false,
    ),
    responseTimeout: responseTimeout,
    streamingBufferWindow: streamingBufferWindow,
  );
}

class StateNotifierTester {
  final StateNotifier notifier;

  final _disposeFns = [];
  var completer = Completer();
  var initial = true;

  StateNotifierTester(this.notifier, {bool fireImmediately = false}) {
    final dispose = notifier.addListener((state) {
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
