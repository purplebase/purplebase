import 'package:models/models.dart';
import 'package:purplebase/src/pool/request_tracker.dart';
import 'package:test/test.dart';

void main() {
  group('RequestTracker', () {
    late RequestTracker tracker;

    setUp(() => tracker = RequestTracker());

    test('registers and finds exact match', () {
      final filters = [RequestFilter(kinds: {1})];
      tracker.register('sub1', filters);

      expect(tracker.findExact(filters), 'sub1');
    });

    test('returns null when no match', () {
      tracker.register('sub1', [RequestFilter(kinds: {1})]);

      expect(tracker.findExact([RequestFilter(kinds: {2})]), isNull);
    });

    test('unregister removes subscription', () {
      final filters = [RequestFilter(kinds: {1})];
      tracker.register('sub1', filters);
      tracker.unregister('sub1');

      expect(tracker.findExact(filters), isNull);
    });

    test('different filter count is not a match', () {
      tracker.register('sub1', [
        RequestFilter(kinds: {1}),
        RequestFilter(kinds: {2}),
      ]);

      expect(tracker.findExact([RequestFilter(kinds: {1})]), isNull);
    });

    test('findCovering delegates to findExact', () {
      final filters = [RequestFilter(kinds: {1})];
      tracker.register('sub1', filters);

      expect(tracker.findCovering(filters), 'sub1');
    });

    test('multiple registrations are tracked independently', () {
      final f1 = [RequestFilter(kinds: {1})];
      final f2 = [RequestFilter(kinds: {2})];
      tracker.register('sub1', f1);
      tracker.register('sub2', f2);

      expect(tracker.findExact(f1), 'sub1');
      expect(tracker.findExact(f2), 'sub2');
    });
  });
}
