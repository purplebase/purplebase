import 'package:purplebase/purplebase.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeRelayUrl', () {
    test('strips trailing slash', () {
      expect(normalizeRelayUrl('wss://relay.com/'), 'wss://relay.com');
    });

    test('lowercases scheme', () {
      expect(normalizeRelayUrl('WSS://relay.com'), 'wss://relay.com');
    });

    test('preserves path', () {
      final url = normalizeRelayUrl('wss://relay.com/path');
      expect(url, contains('/path'));
    });

    test('handles ws:// scheme', () {
      final url = normalizeRelayUrl('ws://localhost:3000');
      expect(url, startsWith('ws://'));
    });
  });
}
