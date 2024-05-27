part of purplebase;

class BaseFileMetadata extends BaseEvent {
  Set<String> get urls => tagMap['url'] ?? {};
  String? get mimeType => tagMap['m']?.firstOrNull;
  String? get hash => tagMap['x']?.firstOrNull;
  String? get size => tagMap['size']?.firstOrNull;
  String? get version => tagMap['version']?.firstOrNull;
  String? get repository => tagMap['repository']?.firstOrNull;
  Set<String> get architectures => tagMap['arch'] ?? {};
  Set<String> get pubkeys => tagMap['p'] ?? {};
}

class BaseRelease extends BaseParameterizableReplaceableEvent {
  String? get url => tagMap['url']?.firstOrNull;
  String get version => identifier.split('@').last;
}

class BaseApp extends BaseParameterizableReplaceableEvent {
  @override
  int get kind => 32267;

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
