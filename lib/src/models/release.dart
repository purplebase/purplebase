part of purplebase;

class BaseRelease extends BaseEvent<BaseRelease> {
  BaseRelease({
    DateTime? createdAt,
    String? content,
    Set<String>? pubkeys,
    Set<String>? tags,
    Set<String>? linkedEvents,
    String? identifier,
    String? url,
  }) : super._(
          content: content,
          createdAt: createdAt,
          pubkeys: pubkeys,
          tags: tags,
          linkedEvents: linkedEvents,
          identifier: identifier,
          additionalEventTags: {('url', url)},
        );

  BaseRelease.fromJson(Map<String, dynamic> map) : super._fromJson(map);

  BaseRelease copyWith({
    DateTime? createdAt,
    String? content,
    Set<String>? pubkeys,
    Set<String>? tags,
    Set<String>? linkedEvents,
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
      tags: tags ?? this.tags,
      linkedEvents: linkedEvents ?? this.linkedEvents,
      url: url ?? this.url,
    );
  }

  String? get url => tagMap['url']?.firstOrNull;
  String get version => identifier!.split('@').last;

  @override
  int get kind => _kindFor<BaseRelease>();
}
