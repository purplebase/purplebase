part of purplebase;

final class BaseAppCurationSet extends BaseEvent<BaseAppCurationSet> {
  BaseAppCurationSet() : super();

  BaseAppCurationSet.fromJson(Map<String, dynamic> map) : super.fromJson(map);

  Set<String> get appIds =>
      linkedReplaceableEvents.map((a) => a.$3).nonNulls.toSet();

  @override
  int get kind => _kindFor<BaseAppCurationSet>();
}
