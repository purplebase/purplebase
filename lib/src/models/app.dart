part of purplebase;

class BaseApp extends BaseEvent with BaseParameterizableReplaceableEvent {
  BaseApp(
      {super.id,
      super.pubkey,
      super.createdAt,
      super.content,
      super.tags,
      super.signature})
      : super(kind: _kindFor<BaseApp>());

  String? get name => tagMap['name']?.firstOrNull;
  String? get repository => tagMap['repository']?.firstOrNull;
  Set<String> get icons => tagMap['icon'] ?? {};
  Set<String> get images => tagMap['image'] ?? {};
  String? get url => tagMap['url']?.firstOrNull;
  Set<String> get pubkeys => tagMap['p'] ?? {};
  Set<String> get tTags => tagMap['t'] ?? {};
  String? get githubStars => tagMap['github_stars']?.firstOrNull;
  String? get githubForks => tagMap['github_forks']?.firstOrNull;
  String? get license => tagMap['license']?.firstOrNull;
  String get aTag => '$kind:$pubkey:${tagMap['d']!.first}';
}
