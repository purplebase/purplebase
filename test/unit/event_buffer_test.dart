import 'dart:async';

import 'package:purplebase/src/pool/event_buffer.dart';
import 'package:test/test.dart';

void main() {
  group('EventBuffer', () {
    test('deduplicates events by id', () {
      final flushedEvents = <List<Map<String, dynamic>>>[];

      final buffer = EventBuffer(
        subscriptionId: 'sub1',
        batchWindow: Duration(seconds: 10),
        totalRelayCount: 2,
        onFlush: (events, _) => flushedEvents.add(events),
        onEose: (_, __) {},
      );

      final event = {'id': 'e1', 'content': 'hello'};
      expect(buffer.addEvent('relay1', event), isTrue);
      expect(buffer.addEvent('relay2', event), isFalse);

      buffer.dispose();
    });

    test('tracks relay sightings per event', () {
      late Map<String, Set<String>> capturedRelays;

      final buffer = EventBuffer(
        subscriptionId: 'sub1',
        batchWindow: Duration(seconds: 10),
        totalRelayCount: 2,
        onFlush: (events, relays) => capturedRelays = relays,
        onEose: (_, __) {},
      );

      buffer.addEvent('relay1', {'id': 'e1'});
      buffer.addEvent('relay2', {'id': 'e1'});
      buffer.flush();

      expect(capturedRelays['e1'], containsAll(['relay1', 'relay2']));
      buffer.dispose();
    });

    test('blocking buffer waits for all EOSE', () {
      final completer = Completer<List<Map<String, dynamic>>>();
      var flushed = false;

      final buffer = EventBuffer(
        subscriptionId: 'sub1',
        batchWindow: Duration(seconds: 10),
        totalRelayCount: 2,
        queryCompleter: completer,
        onFlush: (_, __) => flushed = true,
        onEose: (_, __) {},
      );

      buffer.addEvent('relay1', {'id': 'e1'});
      buffer.markEose('relay1');
      expect(flushed, isFalse);

      buffer.markEose('relay2');
      expect(flushed, isTrue);

      buffer.dispose();
    });

    test('non-blocking buffer flushes on first EOSE', () {
      var flushed = false;

      final buffer = EventBuffer(
        subscriptionId: 'sub1',
        batchWindow: Duration(seconds: 10),
        totalRelayCount: 2,
        onFlush: (_, __) => flushed = true,
        onEose: (_, __) {},
      );

      buffer.addEvent('relay1', {'id': 'e1'});
      buffer.markEose('relay1');
      expect(flushed, isTrue);

      buffer.dispose();
    });

    test('allEoseReceived is accurate', () {
      final buffer = EventBuffer(
        subscriptionId: 'sub1',
        batchWindow: Duration(seconds: 10),
        totalRelayCount: 3,
        onFlush: (_, __) {},
        onEose: (_, __) {},
      );

      expect(buffer.allEoseReceived, isFalse);
      buffer.markEose('r1');
      expect(buffer.allEoseReceived, isFalse);
      buffer.markEose('r2');
      expect(buffer.allEoseReceived, isFalse);
      buffer.markEose('r3');
      expect(buffer.allEoseReceived, isTrue);

      buffer.dispose();
    });

    test('hasEvent checks buffer contents', () {
      final buffer = EventBuffer(
        subscriptionId: 'sub1',
        batchWindow: Duration(seconds: 10),
        totalRelayCount: 1,
        onFlush: (_, __) {},
        onEose: (_, __) {},
      );

      expect(buffer.hasEvent('e1'), isFalse);
      buffer.addEvent('relay1', {'id': 'e1'});
      expect(buffer.hasEvent('e1'), isTrue);

      buffer.dispose();
    });

    test('onEose callback reports event count per relay', () {
      final eoseCounts = <String, int>{};

      // Use blocking mode so flush doesn't clear relay tracking between EOSEs
      final completer = Completer<List<Map<String, dynamic>>>();
      final buffer = EventBuffer(
        subscriptionId: 'sub1',
        batchWindow: Duration(seconds: 10),
        totalRelayCount: 2,
        queryCompleter: completer,
        onFlush: (_, __) {},
        onEose: (count, url) => eoseCounts[url] = count,
      );

      buffer.addEvent('relay1', {'id': 'e1'});
      buffer.addEvent('relay1', {'id': 'e2'});
      buffer.addEvent('relay2', {'id': 'e1'});

      buffer.markEose('relay1');
      expect(eoseCounts['relay1'], 2);

      buffer.markEose('relay2');
      expect(eoseCounts['relay2'], 1);

      buffer.dispose();
    });

    test('dispose completes queryCompleter with empty list', () async {
      final completer = Completer<List<Map<String, dynamic>>>();

      final buffer = EventBuffer(
        subscriptionId: 'sub1',
        batchWindow: Duration(seconds: 10),
        totalRelayCount: 1,
        queryCompleter: completer,
        onFlush: (_, __) {},
        onEose: (_, __) {},
      );

      buffer.dispose();

      final result = await completer.future;
      expect(result, isEmpty);
    });

    test('rejects events with null id', () {
      final buffer = EventBuffer(
        subscriptionId: 'sub1',
        batchWindow: Duration(seconds: 10),
        totalRelayCount: 1,
        onFlush: (_, __) {},
        onEose: (_, __) {},
      );

      expect(buffer.addEvent('relay1', {'content': 'no id'}), isFalse);
      buffer.dispose();
    });
  });
}
