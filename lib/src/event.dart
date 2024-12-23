part of purplebase;

sealed class Event<E extends Event<E>>
    with EquatableMixin
    implements EventBase {
  @override
  final ImmutableInternalEvent event;

  Event.fromJson(Map<String, dynamic> map)
      : event = ImmutableInternalEvent<E>(
            id: map['id'],
            content: map['content'],
            pubkey: map['pubkey'],
            createdAt: (map['created_at'] as int).toDate(),
            tags: toTags(map['tags'] as Iterable),
            signature: map['sig']) {
    if (map['kind'] != event.kind) {
      throw Exception(
          'Kind mismatch! Incoming JSON kind is not of the kind of type $E');
    }

    final kindCheck = switch (event.kind) {
      >= 10000 && < 20000 || 0 || 3 => this is ReplaceableEvent,
      >= 20000 && < 30000 => this is EphemeralEvent,
      >= 30000 && < 40000 => this is ParameterizableReplaceableEvent,
      _ => this is RegularEvent,
    };
    if (!kindCheck) {
      throw Exception('Kind does not match the type of event');
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'id': event.id,
      'content': event.content,
      'created_at': event.createdAt.toInt(),
      'pubkey': event.pubkey,
      'kind': event.kind,
      'tags': toNostrTags(event.tags),
      'sig': event.signature,
    };
  }

  @override
  List<Object?> get props => [event.id];

  // Registerable mappings
  static final Map<String, (int, EventConstructor)> types = {
    'Note': (1, Note.fromJson),
    'App': (32267, App.fromJson)
  };

  static EventConstructor<E>? getConstructor<E extends Event<E>>() {
    final constructor = types[E.toString()]?.$2 as EventConstructor<E>?;
    if (constructor == null) {
      throw Exception('''
Could not find the constructor for $E. Did you forget to register the type?

You can do so by calling: Event.types['$E'] = (kind, $E.fromJson);
''');
    }
    return constructor;
  }
}

sealed class PartialEvent<E extends Event<E>>
    with Signable<E>
    implements PartialEventBase {
  @override
  final PartialInternalEvent event = PartialInternalEvent<E>();

  Map<String, dynamic> toMap() {
    return {
      'content': event.content,
      'created_at': event.createdAt.toInt(),
      'kind': event.kind,
      'tags': toNostrTags(event.tags),
    };
  }

  @override
  String toString() {
    return jsonEncode(toMap());
  }
}

mixin EventBase {
  InternalEvent get event;
}

mixin PartialEventBase implements EventBase {
  @override
  PartialInternalEvent get event;
}

// Internal events

sealed class InternalEvent<E extends Event<E>> {
  final int kind = Event.types[E.toString()]!.$1;
  DateTime get createdAt;
  String get content;
  Map<String, List<String>> get tags;

  String? getTag(String key) => tags[key]?.firstOrNull;
  Set<String> getTagSet(String key) => tags[key]?.toSet() ?? {};
}

final class ImmutableInternalEvent<E extends Event<E>>
    extends InternalEvent<E> {
  final Object id;
  @override
  final DateTime createdAt;
  final String pubkey;
  @override
  final String content;
  @override
  final Map<String, List<String>> tags;
  final String signature;
  ImmutableInternalEvent(
      {required this.id,
      required this.createdAt,
      required this.pubkey,
      required this.tags,
      required this.content,
      required this.signature});
}

final class PartialInternalEvent<E extends Event<E>> extends InternalEvent<E> {
  // No ID, pubkey or signature
  // Kind is inherited
  @override
  String content = '';
  @override
  DateTime createdAt = DateTime.now();
  @override
  Map<String, List<String>> tags = {};

  void setTag(String key, String? value) {
    if (value == null) return;
    tags[key] ??= [];
    tags[key] = [value];
  }
}

// Regular

abstract class RegularEvent<E extends Event<E>> extends Event<E> {
  RegularEvent.fromJson(super.map) : super.fromJson();
}

abstract class RegularPartialEvent<E extends Event<E>>
    extends PartialEvent<E> {}

// Ephemeral

abstract class EphemeralEvent<E extends Event<E>> extends Event<E> {
  EphemeralEvent.fromJson(super.map) : super.fromJson();
}

abstract class EphemeralPartialEvent<E extends Event<E>>
    extends PartialEvent<E> {}

// Replaceable

abstract class ReplaceableEvent<E extends Event<E>> extends Event<E> {
  ReplaceableEvent.fromJson(super.map) : super.fromJson();

  ReplaceableEventLink getReplaceableEventLink({String? pubkey}) =>
      (event.kind, pubkey ?? event.pubkey, null);

  @override
  List<Object?> get props => [getReplaceableEventLink().formatted];
}

abstract class ReplaceablePartialEvent<E extends Event<E>>
    extends PartialEvent<E> {}

// PRE

abstract class ParameterizableReplaceableEvent<E extends Event<E>>
    extends ReplaceableEvent<E> {
  ParameterizableReplaceableEvent.fromJson(super.map) : super.fromJson() {
    if (!event.tags.containsKey('d')) {
      throw Exception('Event must contain a `d` tag');
    }
  }

  String get identifier => event.tags['d']!.first;

  @override
  ReplaceableEventLink getReplaceableEventLink({String? pubkey}) =>
      (event.kind, pubkey ?? event.pubkey, identifier);
}

abstract class ParameterizableReplaceablePartialEvent<E extends Event<E>>
    extends ReplaceablePartialEvent<E> {
  String? get identifier => event.getTag('d');
  set identifier(String? value) => event.setTag('d', value);
}

// Extensions and shit

typedef EventConstructor<E extends Event<E>> = E Function(Map<String, dynamic>);

typedef ReplaceableEventLink = (int, String, String?);

extension RLExtension on ReplaceableEventLink {
  // NOTE: Yes, plain replaceables have a trailing colon
  String get formatted => '${this.$1}:${this.$2}:${this.$3 ?? ''}';
}

extension PExt on PartialEvent {
  String getEventId(String pubkey) {
    final data = [
      0,
      pubkey.toLowerCase(),
      event.createdAt.toInt(),
      event.kind,
      toNostrTags(event.tags),
      event.content
    ];
    final digest =
        sha256.convert(Uint8List.fromList(utf8.encode(json.encode(data))));
    return digest.toString();
  }
}

extension StringExt on String? {
  int? toInt() {
    return this == null ? null : int.tryParse(this!);
  }
}
