part of purplebase;

abstract class BaseEvent<T extends BaseEvent<T>> with EquatableMixin {
  Object? _id;
  String? _pubkey;
  final DateTime? createdAt;
  int get kind;
  final String? content;
  final Set<(String, dynamic)> _tags;
  List<List<String>> get _tagList => _tags
      .map((e) =>
          e.$2 != null ? [e.$1, e.$2.toString(), if (e.$1 == 'zap') '1'] : null)
      .nonNulls
      .toList();
  Set<(String, dynamic)>? additionalEventTags = {};

  String? _signature;

  Object get id => _id!;
  String get pubkey => _pubkey!;
  String get signature => _signature!;

  // Common tags
  Set<String> get linkedEvents => tagMap['e'] ?? {};
  Set<ReplaceableEventLink> get linkedReplaceableEvents {
    return (tagMap['a'] ?? {}).map(
      (e) {
        final [kind, pubkey, ...identifier] = e.split(':');
        return (kind.toInt()!, pubkey, identifier.firstOrNull);
      },
    ).toSet();
  }

  ReplaceableEventLink getReplaceableEventLink() => (kind, pubkey, identifier);

  Set<String> get pubkeys => tagMap['p'] ?? {};
  Set<String> get zapTags => tagMap['zap'] ?? {};
  Set<String> get tags => tagMap['t'] ?? {};
  String? get identifier => tagMap['d']!.firstOrNull;

  var _validated = false;

  BaseEvent({
    DateTime? createdAt,
    String? content,
    Set<String>? pubkeys,
    Set<String>? zapTags,
    Set<String>? tags,
    Set<String>? linkedEvents,
    Set<ReplaceableEventLink>? linkedReplaceableEvents,
    String? identifier,
    Set<(String, dynamic)>? additionalEventTags,
  })  : createdAt = createdAt ?? DateTime.now(),
        content = content ?? '',
        _tags = {
          ...?additionalEventTags,
          ...?pubkeys?.map((e) => ('p', e)),
          ...?zapTags?.map((e) => ('zap', e)),
          // TODO: Allow assigning weight to zaps
          ...?tags?.map((e) => ('t', e)),
          ...?linkedEvents?.map((e) => ('e', e)),
          ...?linkedReplaceableEvents
              ?.map((e) => ('a', '${e.$1}:${e.$2}:${e.$3 ?? ''}')),
          ('d', identifier),
        };

  BaseEvent.fromJson(Map<String, dynamic> map)
      : _id = map['id'],
        _pubkey = map['pubkey'],
        content = map['content'],
        createdAt =
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] * 1000),
        _tags = (map['tags'] as Iterable)
            .map((e) => (e[0].toString(), e[1]?.toString()))
            .toSet(),
        _signature = map['sig'];

  bool get isValid {
    if (_validated) {
      return true;
    }
    return _validated = '$createdAtMs'.length == 10 &&
        _pubkey != null &&
        _signature != null &&
        _id == _eventId(pubkey) &&
        bip340.verify(pubkey, id.toString(), signature);
  }

  String? _eventId(String pubkey) {
    final data = [
      0,
      pubkey.toLowerCase(),
      createdAtMs,
      kind,
      _tagList,
      content
    ];
    final digest =
        sha256.convert(Uint8List.fromList(utf8.encode(json.encode(data))));
    return digest.toString();
  }

  int get createdAtMs => createdAt!.millisecondsSinceEpoch ~/ 1000;

  T sign(String privateKey) {
    this._pubkey = getPublicKey(privateKey);
    this._id = _eventId(pubkey);
    // TODO: Should aux be random? random.nextInt(256)
    final aux = hex.encode(List<int>.generate(32, (i) => 1));
    this._signature = bip340.sign(privateKey, id.toString(), aux);
    return this as T;
  }

  String getPublicKey(String privateKey) {
    return bip340.getPublicKey(privateKey).toLowerCase();
  }

  // [['a', 1], ['a', 2]] => {'a': {1, 2}}
  Map<String, Set<String>> get tagMap {
    return _tags.groupFoldBy<String, Set<String>>(
        (e) => e.$1, (acc, e) => {...?acc, if (e.$2 != null) e.$2!.toString()});
  }

  Map<String, dynamic> toMap() {
    return {
      'id': _id,
      'content': content,
      'created_at': createdAtMs,
      'pubkey': _pubkey,
      'kind': kind,
      'tags': _tagList,
      'sig': _signature,
    };
  }

  @override
  List<Object?> get props => [toMap()];

  @override
  String toString() {
    return jsonEncode(toMap());
  }

  // Kinds

  EventType get eventType {
    return switch (kind) {
      >= 10000 && < 20000 || 0 || 3 => EventType.replaceable,
      >= 20000 && < 30000 => EventType.ephemeral,
      >= 30000 && < 40000 => EventType.parameterizedReplaceable,
      _ => EventType.regular,
    };
  }

  static final Map<int, (String, BaseEvent Function(Map<String, dynamic>))>
      _kinds = {
    0: ('users', BaseUser.fromJson),
    // 3: ('contacts', BaseUser.fromJson),
    1063: ('fileMetadata', BaseFileMetadata.fromJson),
    30063: ('releases', BaseRelease.fromJson),
    30267: ('appCurationSets', BaseAppCurationSet.fromJson),
    32267: ('apps', BaseApp.fromJson)
  };

  static String? typeForKind(int kind) {
    return _kinds[kind]?.$1;
  }

  static T Function(Map<String, dynamic>)? ctorForKind<T extends BaseEvent<T>>(
      int kind) {
    return _kinds[kind]?.$2 as T Function(Map<String, dynamic>)?;
  }

  static int? kindForType<E>(String type) {
    return _kinds.entries.firstWhereOrNull((e) => e.value.$1 == type)?.key;
  }
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

mixin NostrMixin {}

// To be used in clients like:
// class App = BaseApp with NostrMixin;

enum EventType { regular, ephemeral, replaceable, parameterizedReplaceable }

typedef ReplaceableEventLink = (int, String, String?);

extension RLExtension on ReplaceableEventLink {
  String get formatted => '${this.$1}:${this.$2}:${this.$3 ?? ''}';
}
