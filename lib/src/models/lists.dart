part of purplebase;

class BaseAppCurationSet extends BaseParameterizableReplaceableEvent {
  Set<String> get aTags => tagMap['a']!;
}
