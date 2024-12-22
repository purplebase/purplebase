part of purplebase;

mixin InternalEvent {
  int get kind;
  DateTime get createdAt;
  String get content;
  Map<String, List<String>> get tags;
}

abstract class EventBase {
  InternalEvent get event;
  int get kind;
}

abstract class HasMutableEvent extends EventBase {
  @override
  MutableInternalEvent get event;
}

class ImmutableInternalEvent implements InternalEvent {
  // TODO: Allow FD to accept String via parameterized default type
  final Object id;
  @override
  final int kind;
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
      required this.kind,
      required this.createdAt,
      required this.pubkey,
      required this.tags,
      required this.content,
      required this.signature});
}

sealed class Event<E extends Event<E>>
    with EquatableMixin
    implements EventBase {
  late final ImmutableInternalEvent _event;

  @override
  ImmutableInternalEvent get event => _event;

  EventConstructor<E> get constructor;

  String get id => event.id.toString();

  Event.fromJson(Map<String, dynamic> map)
      : _event = ImmutableInternalEvent(
            id: map['id'],
            content: map['content'],
            pubkey: map['pubkey'],
            createdAt: (map['created_at'] as int).toDate(),
            tags: toTags(map['tags'] as Iterable),
            kind: map['kind'],
            signature: map['sig']) {
    // TODO: Assert kind
    // if (kind != event.kind) {
    //   throw Exception('Kind mismatch: $kind != ${event.kind}');
    // }
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

  // >= 10000 && < 20000 || 0 || 3 => EventType.replaceable,
  // >= 20000 && < 30000 => EventType.ephemeral,
  // >= 30000 && < 40000 => EventType.parameterizedReplaceable,
  // _ => EventType.regular,
  @override
  List<Object?> get props => [event.id];

  // Registerable mappings
  static final Map<int, EventConstructor> constructors = {
    1: Note.fromJson,
    32267: App.fromJson
  };
  static final Map<String, int> types = {'Note': 1, 'App': 32267};

  static EventConstructor<E>? getConstructor<E extends Event<E>>(int kind) {
    return constructors[kind] as EventConstructor<E>?;
  }
}

final class PREImmutableInternalEvent extends ImmutableInternalEvent {
  final String identifier;
  PREImmutableInternalEvent(
      {required ImmutableInternalEvent event, required this.identifier})
      : super(
            content: event.content,
            id: event.id,
            createdAt: event.createdAt,
            kind: event.kind,
            pubkey: event.pubkey,
            signature: event.signature,
            tags: event.tags);
}

abstract class ParameterizableReplaceableEvent<E extends Event<E>>
    extends Event<E> {
  // TODO: Should be able to use _event
  late final PREImmutableInternalEvent __event;

  @override
  PREImmutableInternalEvent get event => __event;

  ParameterizableReplaceableEvent.fromJson(super.map) : super.fromJson() {
    __event = PREImmutableInternalEvent(
      event: super.event,
      identifier: super.event.tags['d']!.first,
    );
    // TODO assert kind number correct
  }

  ReplaceableEventLink getReplaceableEventLink({String? pubkey}) =>
      (kind, pubkey ?? event.pubkey, event.identifier);

  @override
  List<Object?> get props => [getReplaceableEventLink().formatted];
}

final class PREMutableInternalEvent extends MutableInternalEvent {
  String? identifier;
  PREMutableInternalEvent(super.kind);
}

abstract class ParameterizableReplaceablePartialEvent<E extends Event<E>>
    extends PartialEvent<E> {
  @override
  PREMutableInternalEvent get event => super.event as PREMutableInternalEvent;

  ParameterizableReplaceablePartialEvent() {
    super.event = PREMutableInternalEvent(kind);
  }
}

//

typedef EventConstructor<E extends Event<E>> = E Function(Map<String, dynamic>);

typedef ReplaceableEventLink = (int, String, String?);

extension RLExtension on ReplaceableEventLink {
  // NOTE: Yes, NPREs have a trailing colon
  String get formatted => '${this.$1}:${this.$2}:${this.$3 ?? ''}';
}

enum EventType { regular, ephemeral, replaceable, parameterizedReplaceable }

class MutableInternalEvent implements InternalEvent {
  MutableInternalEvent(this.kind);
  // No ID, pubkey or signature
  // Kind is immutable
  @override
  final int kind;
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

abstract class PartialEvent<E extends Event<E>>
    with Signable<E>
    implements HasMutableEvent {
  @override
  late final MutableInternalEvent event;

  PartialEvent() {
    event = MutableInternalEvent(kind);
  }

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

extension PExt on PartialEvent {
  String getEventId(String pubkey) {
    final data = [
      0,
      pubkey.toLowerCase(),
      event.createdAt.toInt(),
      kind,
      toNostrTags(event.tags),
      event.content
    ];
    final digest =
        sha256.convert(Uint8List.fromList(utf8.encode(json.encode(data))));
    return digest.toString();
  }
}
