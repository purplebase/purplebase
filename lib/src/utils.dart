part of purplebase;

extension IntExt on int {
  DateTime toDate() => DateTime.fromMillisecondsSinceEpoch(this * 1000);
}

extension DateTimeExt on DateTime {
  int toInt() => millisecondsSinceEpoch ~/ 1000;
}

class BaseUtil {
  static String? getTag(Iterable tags, String key) {
    return tags.firstWhereOrNull((tag) => tag.first == key)?[1];
  }

  static Set<String> getTagSet(Iterable tags, String key) => tags
      .where((tag) => tag.first == key)
      .map((tag) => tag[1]?.toString())
      .nonNulls
      .toSet();

  static bool containsTag(Iterable tags, String key) {
    return tags.firstWhereOrNull((tag) => tag.first == key) != null;
  }

  static String getPublicKey(String privateKey) {
    return bip340.getPublicKey(privateKey).toLowerCase();
  }
}

final kBolt11Regexp = RegExp(r'lnbc(\d+)([munp])');

int getSatsFromBolt11(String bolt11) {
  try {
    final m = kBolt11Regexp.allMatches(bolt11);
    final [baseAmountInBitcoin, multiplier] = m.first.groups([1, 2]);
    final a = int.tryParse(baseAmountInBitcoin!)!;
    final amountInBitcoin = switch (multiplier!) {
      'm' => a * 0.001,
      'u' => a * 0.000001,
      'n' => a * 0.000000001,
      'p' => a * 0.000000000001,
      _ => a,
    };
    // Return converted to sats
    return (amountInBitcoin * 100000000).floor();
  } catch (_) {
    // Do not bother throwing an exception, 0 sat should still convey that it was an error
    return 0;
  }
}
