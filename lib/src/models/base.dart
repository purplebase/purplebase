part of purplebase;

class BaseEvent with EquatableMixin {
  late final Object? id;
  late final String pubkey;
  late final DateTime createdAt;
  late final String content;
  late final int kind;
  late final List<List<String>> tags;
  String? signature;

  BaseEvent();

  BaseEvent.partial({int? kind, String? content, DateTime? createdAt})
      : content = content ?? '',
        kind = kind ?? 1,
        createdAt = createdAt ?? DateTime.now(),
        tags = const [];

  bool get isValid {
    return '$createdAtMs'.length == 10 &&
        id == _eventId &&
        bip340.verify(pubkey, id.toString(), signature!);
  }

  String get _eventId {
    final data = [0, pubkey.toLowerCase(), createdAtMs, kind, tags, content];
    final digest =
        sha256.convert(Uint8List.fromList(utf8.encode(json.encode(data))));
    return digest.toString();
  }

  int get createdAtMs => createdAt.millisecondsSinceEpoch ~/ 1000;

  final random = Random.secure();

  BaseEvent sign(String privateKey) {
    pubkey = getPublicKey(privateKey);
    id = _eventId;
    final r = hex.encode(List<int>.generate(32, (i) => random.nextInt(256)));
    signature = bip340.sign(privateKey, id.toString(), r);
    return this;
  }

  static String getPublicKey(String privateKey) {
    return bip340.getPublicKey(privateKey).toLowerCase();
  }

  // [['a', 1], ['a', 2]] => {'a': {1, 2}}
  Map<String, Set<String>> get tagMap {
    return tags.groupFoldBy<String, Set<String>>(
        (e) => e.first, (acc, e) => {...?acc, e[1]});
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'content': content,
      'created_at': createdAtMs,
      'pubkey': pubkey,
      'kind': kind,
      'tags': tags,
      'sig': signature,
    };
  }

  BaseEvent.fromMap(Map<String, dynamic> map)
      : id = map['id'],
        content = map['content'],
        pubkey = map['pubkey'],
        createdAt = DateTime.fromMillisecondsSinceEpoch(
            (map['created_at'] as int) * 1000),
        kind = map['kind'],
        tags = [for (final t in map['tags']) List<String>.from(t)],
        signature = map['sig'];

  @override
  List<Object?> get props => [id];

  @override
  String toString() {
    return jsonEncode(toMap());
  }
}
