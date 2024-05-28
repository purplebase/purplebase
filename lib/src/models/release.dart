part of purplebase;

class BaseRelease extends BaseEvent with BaseParameterizableReplaceableEvent {
  BaseRelease(
      {super.id,
      super.pubkey,
      super.createdAt,
      super.content,
      super.tags,
      super.signature})
      : super(kind: _kindFor<BaseRelease>());

  String? get url => tagMap['url']?.firstOrNull;
  String get version => identifier.split('@').last;
}
