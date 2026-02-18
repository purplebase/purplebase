import 'package:purplebase/src/db/codec.dart';
import 'package:test/test.dart';

void main() {
  group('EventCodec', () {
    group('storageId', () {
      test('regular event uses event id', () {
        final event = {'id': 'abc123', 'kind': 1, 'pubkey': 'pub1', 'tags': []};
        expect(EventCodec.storageId(event), 'abc123');
      });

      test('replaceable kind 0 uses kind:pubkey:', () {
        final event = {'id': 'x', 'kind': 0, 'pubkey': 'pub1', 'tags': []};
        expect(EventCodec.storageId(event), '0:pub1:');
      });

      test('replaceable kind 3 uses kind:pubkey:', () {
        final event = {'id': 'x', 'kind': 3, 'pubkey': 'pub1', 'tags': []};
        expect(EventCodec.storageId(event), '3:pub1:');
      });

      test('replaceable kind 10002 uses kind:pubkey:', () {
        final event = {'id': 'x', 'kind': 10002, 'pubkey': 'pub1', 'tags': []};
        expect(EventCodec.storageId(event), '10002:pub1:');
      });

      test('parameterized replaceable uses kind:pubkey:d', () {
        final event = {
          'id': 'x',
          'kind': 30000,
          'pubkey': 'pub1',
          'tags': [
            ['d', 'myapp'],
          ],
        };
        expect(EventCodec.storageId(event), '30000:pub1:myapp');
      });

      test('different d-tags produce different IDs', () {
        final eventA = {
          'id': 'x',
          'kind': 30000,
          'pubkey': 'pub1',
          'tags': [
            ['d', 'a'],
          ],
        };
        final eventB = {
          'id': 'y',
          'kind': 30000,
          'pubkey': 'pub1',
          'tags': [
            ['d', 'b'],
          ],
        };
        expect(EventCodec.storageId(eventA), isNot(EventCodec.storageId(eventB)));
      });
    });

    group('encode/decode roundtrip', () {
      test('preserves event fields', () {
        final events = [
          {
            'id': 'event1',
            'pubkey': 'pub1',
            'kind': 1,
            'created_at': 1700000000,
            'content': 'hello world',
            'tags': [
              ['t', 'nostr'],
            ],
            'sig': 'sig1',
          },
        ];

        final (encoded, _) = EventCodec.encode(events);
        expect(encoded, hasLength(1));

        final decoded = EventCodec.decode(encoded.map((e) {
          return {
            'id': e[':id'],
            'pubkey': e[':pubkey'],
            'kind': e[':kind'],
            'created_at': e[':created_at'],
            'blob': e[':blob'],
          };
        }));

        expect(decoded, hasLength(1));
        expect(decoded.first['content'], 'hello world');
        expect(decoded.first['pubkey'], 'pub1');
        expect(decoded.first['kind'], 1);
        expect(decoded.first['sig'], 'sig1');
        expect(decoded.first['tags'], [
          ['t', 'nostr'],
        ]);
      });

      test('handles special characters', () {
        final events = [
          {
            'id': 'evt_special',
            'pubkey': 'pub1',
            'kind': 1,
            'created_at': 1700000000,
            'content': 'Test with émojis 🚀⚡️ and ünïcödé 中文',
            'tags': [],
            'sig': 'sig1',
          },
        ];

        final (encoded, _) = EventCodec.encode(events);
        final decoded = EventCodec.decode(encoded.map((e) => {
              'id': e[':id'],
              'pubkey': e[':pubkey'],
              'kind': e[':kind'],
              'created_at': e[':created_at'],
              'blob': e[':blob'],
            }));

        expect(
            decoded.first['content'], 'Test with émojis 🚀⚡️ and ünïcödé 中文');
      });

      test('strips signature when keepSignatures is false', () {
        final events = [
          {
            'id': 'nosig',
            'pubkey': 'pub1',
            'kind': 1,
            'created_at': 1700000000,
            'content': 'no sig',
            'tags': [],
            'sig': 'should_be_stripped',
          },
        ];

        final (encoded, _) =
            EventCodec.encode(events, keepSignatures: false);
        final decoded = EventCodec.decode(encoded.map((e) => {
              'id': e[':id'],
              'pubkey': e[':pubkey'],
              'kind': e[':kind'],
              'created_at': e[':created_at'],
              'blob': e[':blob'],
            }));

        expect(decoded.first.containsKey('sig'), isFalse);
      });

      test('sanitizes unexpected fields', () {
        final events = [
          {
            'id': 'evt1',
            'pubkey': 'pub1',
            'kind': 1,
            'created_at': 1700000000,
            'content': 'clean',
            'tags': [],
            'sig': 'sig1',
            'extra_field': 'should be removed',
            'another': 42,
          },
        ];

        final (encoded, _) = EventCodec.encode(events);
        final first = encoded.first;
        expect(first.containsKey(':extra_field'), isFalse);
        expect(first.containsKey(':another'), isFalse);
      });
    });

    group('encode tags', () {
      test('returns tags in tagsForId map', () {
        final events = [
          {
            'id': 'evt_tags',
            'pubkey': 'pub1',
            'kind': 1,
            'created_at': 1700000000,
            'content': 'tagged',
            'tags': [
              ['t', 'nostr'],
              ['p', 'somepubkey'],
            ],
            'sig': 'sig1',
          },
        ];

        final (_, tagsForId) = EventCodec.encode(events);
        expect(tagsForId['evt_tags'], hasLength(2));
      });
    });
  });
}
