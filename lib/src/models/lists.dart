part of purplebase;

class BaseAppCurationSet extends BaseEvent
    with BaseParameterizableReplaceableEvent {
  BaseAppCurationSet(
      {super.id,
      super.pubkey,
      super.createdAt,
      super.content,
      super.tags,
      super.signature})
      : super(kind: _kindFor<BaseAppCurationSet>());

  Set<String> get aTags => tagMap['a']!;
}
