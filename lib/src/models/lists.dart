part of purplebase;

class BaseAppCurationSet extends BaseEvent<BaseAppCurationSet>
    with ParameterizableReplaceableEvent<BaseAppCurationSet> {
  BaseAppCurationSet() : super();

  BaseAppCurationSet.fromJson(Map<String, dynamic> map) : super.fromJson(map);

  Set<String> get appIds =>
      linkedReplaceableEvents.map((a) => a.$3).nonNulls.toSet();
}
