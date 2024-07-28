part of purplebase;

final class BaseAppCurationSet extends BaseEvent<BaseAppCurationSet> {
  BaseAppCurationSet() : super._();

  Set<String> get aTags => tagMap['a']!;
  Set<String> get appIds => aTags.map((a) => a.split(':')[2]).toSet();

  @override
  int get kind => _kindFor<BaseAppCurationSet>();
}
