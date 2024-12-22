part of purplebase;

List<List<String>> toNostrTags(Map<String, List<String>> tags) {
  return [
    for (final t in tags.entries)
      for (final e in t.value) [t.key, e],
  ];
}

Map<String, List<String>> toTags(Iterable tags) {
  return tags.groupFoldBy<String, List<String>>(
      (e) => e[0], (acc, e) => [...?acc, ...(e..removeAt(0))]);
}

extension IntExt on int {
  DateTime toDate() => DateTime.fromMillisecondsSinceEpoch(this * 1000);
}

extension on String? {
  int? toInt() {
    return this == null ? null : int.tryParse(this!);
  }
}

extension DateTimeExt on DateTime {
  int toInt() => millisecondsSinceEpoch ~/ 1000;
}

class BaseUtil {
  static String getPublicKey(String privateKey) {
    return bip340.getPublicKey(privateKey).toLowerCase();
  }
}
