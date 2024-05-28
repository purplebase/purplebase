part of purplebase;

class BaseEvent with EquatableMixin {
  final Object? id;
  final String? pubkey;
  final DateTime createdAt;
  final int kind;
  final String content;
  final List<List<String>> tags;
  final String? signature;

  var _validated = false;

  BaseEvent(
      {this.id,
      this.pubkey,
      DateTime? createdAt,
      this.kind = 1,
      this.content = '',
      this.tags = const [],
      this.signature})
      : createdAt = createdAt ?? DateTime.now();

  bool get isValid {
    if (_validated) {
      return true;
    }
    return _validated = '$createdAtMs'.length == 10 &&
        pubkey != null &&
        signature != null &&
        id == _eventId(pubkey!) &&
        bip340.verify(pubkey!, id!.toString(), signature!);
  }

  String? _eventId(String pubkey) {
    final data = [0, pubkey.toLowerCase(), createdAtMs, kind, tags, content];
    final digest =
        sha256.convert(Uint8List.fromList(utf8.encode(json.encode(data))));
    return digest.toString();
  }

  int get createdAtMs => createdAt.millisecondsSinceEpoch ~/ 1000;

  BaseEvent sign(String privateKey) {
    final pubkey = getPublicKey(privateKey);
    final id = _eventId(pubkey)!;
    final aux = hex.encode(List<int>.generate(32, (i) => random.nextInt(256)));
    return BaseEvent(
      id: id,
      pubkey: pubkey,
      kind: kind,
      createdAt: createdAt,
      content: content,
      tags: tags,
      signature: bip340.sign(privateKey, id, aux),
    );
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

  @override
  List<Object?> get props => [signature ?? id];

  @override
  String toString() {
    return jsonEncode(toMap());
  }

  static Map<int, String> kinds = {
    0: 'users',
    3: 'users',
    1063: 'fileMetadata',
    30063: 'releases',
    30267: 'appCurationSets',
    32267: 'apps'
  };

  static int? kindForType(String type) {
    return kinds.entries.firstWhereOrNull((e) => e.value == type)?.key;
  }
}

mixin BaseReplaceableEvent on BaseEvent {}

mixin BaseParameterizableReplaceableEvent on BaseEvent {
  String get identifier => tagMap['d']!.first;
}

int _kindFor<T>() {
  // Call substring to remove 'Base' prefix
  return BaseEvent.kindForType(
      T.toString().substring(4).lowercaseFirst.toPluralForm())!;
}

extension on String {
  String get lowercaseFirst {
    return "${this[0].toLowerCase()}${substring(1)}";
  }
}
