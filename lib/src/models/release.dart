part of purplebase;

class BaseRelease extends BaseEvent<BaseRelease>
    with ParameterizableReplaceableEvent<BaseRelease> {
  BaseRelease({
    DateTime? createdAt,
    String? content,
    Set<String>? pubkeys,
    Set<String>? zapTags,
    Set<String>? tags,
    Set<String>? linkedEvents,
    Set<ReplaceableEventLink>? linkedReplaceableEvents,
    String? identifier,
    String? url,
    Set<(String, dynamic)>? additionalEventTags,
  }) : super(
          content: content,
          createdAt: createdAt,
          pubkeys: pubkeys,
          zapTags: zapTags,
          tags: tags,
          linkedEvents: linkedEvents,
          linkedReplaceableEvents: linkedReplaceableEvents,
          identifier: identifier,
          additionalEventTags: {
            ...?additionalEventTags,
            ('url', url),
          },
        );

  BaseRelease.fromJson(super.map) : super.fromJson();

  BaseRelease copyWith({
    DateTime? createdAt,
    String? content,
    Set<String>? pubkeys,
    Set<String>? zapTags,
    Set<String>? tags,
    String? identifier,
    Set<String>? linkedEvents,
    Set<ReplaceableEventLink>? linkedReplaceableEvents,
    String? name,
    String? repository,
    Set<String>? icons,
    Set<String>? images,
    String? url,
    String? license,
  }) {
    return BaseRelease(
      createdAt: createdAt ?? this.createdAt,
      content: content ?? this.content,
      pubkeys: pubkeys ?? this.pubkeys,
      zapTags: zapTags ?? this.zapTags,
      tags: tags ?? this.tags,
      identifier: identifier ?? this.identifier,
      linkedEvents: linkedEvents ?? this.linkedEvents,
      linkedReplaceableEvents:
          linkedReplaceableEvents ?? this.linkedReplaceableEvents,
      url: url ?? this.url,
    );
  }

  @override
  int get kind => _kindFor<BaseRelease>();

  String? get url => tagMap['url']?.firstOrNull;
  String get version => identifier.split('@').last;
}
