import 'package:models/models.dart';
import 'package:test/test.dart';

Future<void> main() async {
  group('LocalAndRemoteSource.cachedFor', () {
    test('forces stream to false when set', () {
      final source = LocalAndRemoteSource(
        relays: 'test',
        stream: true, // Explicitly set to true
        cachedFor: Duration(milliseconds: 100),
      );

      // cachedFor should force stream to false
      expect(source.stream, isFalse);
    });

    test('stream respects value when cachedFor is null', () {
      final sourceTrue = LocalAndRemoteSource(
        relays: 'test',
        stream: true,
        cachedFor: null,
      );
      expect(sourceTrue.stream, isTrue);

      final sourceFalse = LocalAndRemoteSource(
        relays: 'test',
        stream: false,
        cachedFor: null,
      );
      expect(sourceFalse.stream, isFalse);
    });

    test('copyWith preserves cachedFor when not specified', () {
      final source = LocalAndRemoteSource(
        relays: 'test',
        cachedFor: Duration(milliseconds: 100),
      );

      final copied = source.copyWith(relays: 'other');

      expect(copied.cachedFor, Duration(milliseconds: 100));
      expect(copied.relays, 'other');
      expect(copied.stream, isFalse); // still forced by cachedFor
    });

    test('copyWith can update cachedFor', () {
      final source = LocalAndRemoteSource(
        relays: 'test',
        cachedFor: Duration(milliseconds: 100),
      );

      final copied = source.copyWith(cachedFor: Duration(milliseconds: 50));

      expect(copied.cachedFor, Duration(milliseconds: 50));
    });

    test('props includes cachedFor for equality', () {
      final source1 = LocalAndRemoteSource(
        relays: 'test',
        cachedFor: Duration(milliseconds: 100),
      );

      final source2 = LocalAndRemoteSource(
        relays: 'test',
        cachedFor: Duration(milliseconds: 100),
      );

      final source3 = LocalAndRemoteSource(
        relays: 'test',
        cachedFor: Duration(milliseconds: 200),
      );

      final source4 = LocalAndRemoteSource(relays: 'test', cachedFor: null);

      expect(source1, equals(source2));
      expect(source1, isNot(equals(source3)));
      expect(source1, isNot(equals(source4)));
    });

    test('default cachedFor is null', () {
      final source = LocalAndRemoteSource(relays: 'test');

      expect(source.cachedFor, isNull);
      expect(source.stream, isTrue); // default stream is true
    });

    test('toString includes cachedFor info', () {
      final source = LocalAndRemoteSource(
        relays: 'test',
        cachedFor: Duration(milliseconds: 100),
      );

      final str = source.toString();
      expect(str, contains('LocalAnd'));
      expect(str, contains('stream=false'));
    });
  });

  group('Utils.isEventReplaceable', () {
    test('kind 0 (Profile) is replaceable', () {
      expect(Utils.isEventReplaceable(0), isTrue);
    });

    test('kind 3 (ContactList) is replaceable', () {
      expect(Utils.isEventReplaceable(3), isTrue);
    });

    test('kind 1 (Note) is not replaceable', () {
      expect(Utils.isEventReplaceable(1), isFalse);
    });

    test('kind 7 (Reaction) is not replaceable', () {
      expect(Utils.isEventReplaceable(7), isFalse);
    });

    test('kinds 10000-19999 are replaceable', () {
      expect(Utils.isEventReplaceable(10000), isTrue);
      expect(Utils.isEventReplaceable(10002), isTrue);
      expect(Utils.isEventReplaceable(19999), isTrue);
    });

    test('kinds 30000-39999 are replaceable', () {
      expect(Utils.isEventReplaceable(30000), isTrue);
      expect(Utils.isEventReplaceable(30023), isTrue);
      expect(Utils.isEventReplaceable(39999), isTrue);
    });

    test('kinds outside ranges are not replaceable', () {
      expect(Utils.isEventReplaceable(9999), isFalse);
      expect(Utils.isEventReplaceable(20000), isFalse);
      expect(Utils.isEventReplaceable(29999), isFalse);
      expect(Utils.isEventReplaceable(40000), isFalse);
    });
  });
}
