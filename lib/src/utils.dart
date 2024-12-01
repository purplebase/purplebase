part of purplebase;

Map<String, Set<String>> tagsToMap(tags) {
  final list = [
    for (final tuple in tags)
      List.from(tuple).map((e) => e?.toString()).toList()
  ];
  return list.groupFoldBy<String, Set<String>>(
      (e) => e[0]!, (acc, e) => {...?acc, if (e[1] != null) e[1].toString()});
}

extension StringExt on String {
  String get lowercaseFirst {
    return "${this[0].toLowerCase()}${substring(1)}";
  }

  ReplaceableEventLink toReplaceableLink() {
    final [kind, pubkey, ...identifier] = split(':');
    return (kind.toInt()!, pubkey, identifier.firstOrNull);
  }
}

extension IntExt on int {
  DateTime toDate() => DateTime.fromMillisecondsSinceEpoch(this * 1000);
}

extension DateTimeExt on DateTime {
  int toInt() => millisecondsSinceEpoch ~/ 1000;
}

EventType getEventType(int kind) {
  return switch (kind) {
    >= 10000 && < 20000 || 0 || 3 => EventType.replaceable,
    >= 20000 && < 30000 => EventType.ephemeral,
    >= 30000 && < 40000 => EventType.parameterizedReplaceable,
    _ => EventType.regular,
  };
}
