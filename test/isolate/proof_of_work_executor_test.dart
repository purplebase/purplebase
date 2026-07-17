import 'dart:isolate';

import 'package:models/models.dart';
import 'package:purplebase/purplebase.dart';
import 'package:test/test.dart';

void main() {
  const pubkey =
      'a9434ee165ed01b286becfc2771ef1705d3537d051b387288898cc00d5c885be';

  PartialEvent<Model<dynamic>> event() => PartialEvent<Model<dynamic>>({
    'content': 'private state',
    'created_at': 1700000000,
    'kind': 30078,
    'tags': [
      ['d', 'zapstore-settings'],
    ],
  }, 30078);

  test('mines on a worker isolate and mutates only on success', () async {
    final executor = IsolateProofOfWorkExecutor();
    addTearDown(executor.dispose);
    final partial = event()..tags.add(['-']);

    final result = await executor.mine(
      partial,
      pubkey: pubkey,
      options: ProofOfWorkOptions(
        difficulty: 4,
        maxAttempts: 100000,
        timeout: const Duration(seconds: 5),
      ),
    );

    expect(executor.lastWorkerIsolateId, isNot(Isolate.current.hashCode));
    expect(result.id, Utils.getEventId(partial, pubkey));
    expect(
      Nip13.isValidProof(
        id: result.id,
        tags: partial.tags,
        minimumDifficulty: 4,
      ),
      isTrue,
    );
    expect(
      partial.tags.where((tag) => tag.length == 1 && tag.single == '-'),
      isNotEmpty,
    );
  });

  test(
    'cancellation stops an in-flight worker without mutating tags',
    () async {
      final executor = IsolateProofOfWorkExecutor();
      addTearDown(executor.dispose);
      final partial = event();
      final originalTags = [
        for (final tag in partial.tags) List<String>.of(tag),
      ];

      final mining = executor.mine(
        partial,
        pubkey: pubkey,
        options: ProofOfWorkOptions(
          difficulty: 256,
          maxAttempts: 1 << 30,
          timeout: const Duration(minutes: 1),
        ),
      );
      executor.cancelAll();

      await expectLater(mining, throwsA(isA<ProofOfWorkCancelled>()));
      expect(partial.tags, originalTags);
    },
  );

  test('propagates mining limits without mutating tags', () async {
    final executor = IsolateProofOfWorkExecutor();
    addTearDown(executor.dispose);
    final partial = event();
    final originalTags = [for (final tag in partial.tags) List<String>.of(tag)];

    await expectLater(
      executor.mine(
        partial,
        pubkey: pubkey,
        options: ProofOfWorkOptions(
          difficulty: 256,
          maxAttempts: 1,
          timeout: const Duration(minutes: 1),
        ),
      ),
      throwsA(isA<ProofOfWorkLimitExceeded>()),
    );
    expect(partial.tags, originalTags);
  });

  test('mines concurrent operations independently', () async {
    final executor = IsolateProofOfWorkExecutor();
    addTearDown(executor.dispose);
    final first = event();
    final second = event()..content = 'other private state';

    final results = await Future.wait([
      executor.mine(
        first,
        pubkey: pubkey,
        options: ProofOfWorkOptions(difficulty: 2),
      ),
      executor.mine(
        second,
        pubkey: pubkey,
        options: ProofOfWorkOptions(difficulty: 2),
      ),
    ]);

    expect(results.first.id, isNot(results.last.id));
    expect(Nip13.isValidProof(id: results.first.id, tags: first.tags), isTrue);
    expect(Nip13.isValidProof(id: results.last.id, tags: second.tags), isTrue);
  });
}
