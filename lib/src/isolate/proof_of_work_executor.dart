import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:models/models.dart';

/// Mines NIP-13 proof of work in short-lived worker isolates.
///
/// Each operation owns one isolate so cancellation can stop CPU work
/// immediately without affecting relay or storage jobs.
final class IsolateProofOfWorkExecutor implements ProofOfWorkExecutor {
  final Set<_MiningOperation> _operations = {};
  bool _disposed = false;

  @visibleForTesting
  int? lastWorkerIsolateId;

  @override
  Future<ProofOfWorkResult> mine<E extends Model<dynamic>>(
    PartialEvent<E> event, {
    required String pubkey,
    required ProofOfWorkOptions options,
  }) async {
    if (_disposed) {
      throw StateError('Proof-of-work executor has been disposed');
    }

    final operation = _MiningOperation();
    _operations.add(operation);
    try {
      final payload = await operation.run(
        event: event,
        pubkey: pubkey,
        options: options,
      );
      lastWorkerIsolateId = payload.workerIsolateId;
      event.tags = payload.tags;
      return payload.result;
    } finally {
      _operations.remove(operation);
    }
  }

  /// Cancels every in-flight mining operation owned by this executor.
  void cancelAll() {
    for (final operation in _operations.toList(growable: false)) {
      operation.cancel();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelAll();
  }
}

final class _MiningOperation {
  final Completer<_MiningPayload> _completer = Completer<_MiningPayload>();
  ReceivePort? _port;
  StreamSubscription<dynamic>? _subscription;
  Isolate? _isolate;
  bool _cancelled = false;

  Future<_MiningPayload> run({
    required PartialEvent<dynamic> event,
    required String pubkey,
    required ProofOfWorkOptions options,
  }) {
    _start(event: event, pubkey: pubkey, options: options);
    return _completer.future.whenComplete(_cleanup);
  }

  Future<void> _start({
    required PartialEvent<dynamic> event,
    required String pubkey,
    required ProofOfWorkOptions options,
  }) async {
    final port = ReceivePort();
    _port = port;
    _subscription = port.listen(_handleMessage);

    try {
      final isolate = await Isolate.spawn<Map<String, dynamic>>(
        _mineInWorker,
        {
          'sendPort': port.sendPort,
          'event': {
            'content': event.content,
            'created_at': event.createdAt.millisecondsSinceEpoch ~/ 1000,
            'kind': event.kind,
            'tags': [for (final tag in event.tags) List<String>.of(tag)],
          },
          'pubkey': pubkey,
          'difficulty': options.difficulty,
          'timeoutUs': options.timeout.inMicroseconds,
          'maxAttempts': options.maxAttempts,
          'batchSize': options.batchSize,
          'startNonce': options.startNonce,
        },
        onExit: port.sendPort,
        onError: port.sendPort,
        errorsAreFatal: true,
        debugName: 'purplebase-nip13',
      );
      _isolate = isolate;
      if (_cancelled) {
        isolate.kill(priority: Isolate.immediate);
      }
    } catch (error, stackTrace) {
      _completeError(error, stackTrace);
    }
  }

  void _handleMessage(dynamic message) {
    if (_completer.isCompleted) return;

    if (message is Map) {
      final payload = Map<String, dynamic>.from(message);
      if (payload['ok'] == true) {
        final tags = (payload['tags'] as List)
            .map((tag) => (tag as List).cast<String>())
            .toList();
        _completer.complete(
          _MiningPayload(
            result: ProofOfWorkResult(
              id: payload['id'] as String,
              nonce: payload['nonce'] as int,
              difficulty: payload['difficulty'] as int,
              attempts: payload['attempts'] as int,
              elapsed: Duration(microseconds: payload['elapsedUs'] as int),
            ),
            tags: tags,
            workerIsolateId: payload['workerIsolateId'] as int,
          ),
        );
        return;
      }

      if (payload['type'] == 'limit') {
        _completeError(
          ProofOfWorkLimitExceeded(
            targetDifficulty: payload['targetDifficulty'] as int,
            attempts: payload['attempts'] as int,
            elapsed: Duration(microseconds: payload['elapsedUs'] as int),
          ),
          StackTrace.fromString(payload['stack'] as String? ?? ''),
        );
        return;
      }

      _completeError(
        StateError(payload['error'] as String? ?? 'PoW worker failed'),
        StackTrace.fromString(payload['stack'] as String? ?? ''),
      );
      return;
    }

    if (message is List && message.length == 2) {
      _completeError(
        StateError('PoW worker crashed: ${message.first}'),
        StackTrace.fromString(message.last.toString()),
      );
      return;
    }

    // onExit sends null. A normal result is sent before isolate exit.
    if (message == null) {
      _completeError(StateError('PoW worker exited without a result'));
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    _completeError(const ProofOfWorkCancelled());
  }

  void _completeError(Object error, [StackTrace? stackTrace]) {
    if (_completer.isCompleted) return;
    _completer.completeError(error, stackTrace ?? StackTrace.current);
  }

  Future<void> _cleanup() async {
    _isolate = null;
    await _subscription?.cancel();
    _subscription = null;
    _port?.close();
    _port = null;
  }
}

final class _MiningPayload {
  const _MiningPayload({
    required this.result,
    required this.tags,
    required this.workerIsolateId,
  });

  final ProofOfWorkResult result;
  final List<List<String>> tags;
  final int workerIsolateId;
}

Future<void> _mineInWorker(Map<String, dynamic> args) async {
  final sendPort = args['sendPort'] as SendPort;
  try {
    final map = Map<String, dynamic>.from(args['event'] as Map);
    final event = PartialEvent<Model<dynamic>>(map, map['kind'] as int);
    event.tags = (map['tags'] as List)
        .map((tag) => (tag as List).cast<String>())
        .toList();
    final result = await Nip13.mine(
      event,
      pubkey: args['pubkey'] as String,
      options: ProofOfWorkOptions(
        difficulty: args['difficulty'] as int,
        timeout: Duration(microseconds: args['timeoutUs'] as int),
        maxAttempts: args['maxAttempts'] as int,
        batchSize: args['batchSize'] as int,
        startNonce: args['startNonce'] as int,
      ),
    );
    sendPort.send({
      'ok': true,
      'id': result.id,
      'nonce': result.nonce,
      'difficulty': result.difficulty,
      'attempts': result.attempts,
      'elapsedUs': result.elapsed.inMicroseconds,
      'tags': event.tags,
      'workerIsolateId': Isolate.current.hashCode,
    });
  } on ProofOfWorkLimitExceeded catch (error, stackTrace) {
    sendPort.send({
      'ok': false,
      'type': 'limit',
      'targetDifficulty': error.targetDifficulty,
      'attempts': error.attempts,
      'elapsedUs': error.elapsed.inMicroseconds,
      'stack': stackTrace.toString(),
    });
  } catch (error, stackTrace) {
    sendPort.send({
      'ok': false,
      'type': 'unknown',
      'error': error.toString(),
      'stack': stackTrace.toString(),
    });
  }
}
