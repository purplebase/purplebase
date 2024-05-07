part of purplebase;

mixin BaseFileMetadata on BaseEvent {
  Set<String> get urls => tagMap['url'] ?? {};
  String? get mimeType => tagMap['m']?.firstOrNull;
  String? get hash => tagMap['x']?.firstOrNull;
  String? get size => tagMap['size']?.firstOrNull;
  String? get version => tagMap['version']?.firstOrNull;
  String? get repository => tagMap['repository']?.firstOrNull;
  Set<String> get architectures => tagMap['arch'] ?? {};
  Set<String> get pubkeys => tagMap['p'] ?? {};
}

mixin BaseRelease on BaseEvent {
  String? get url => tagMap['url']?.firstOrNull;
  String get identifier => tagMap['d']!.first;
  String get version => identifier.split('@').last;
}

mixin BaseApp on BaseEvent {
  @override
  int get kind => 32267;

  String? get identifier => tagMap['d']?.firstOrNull;
  String? get name => tagMap['name']!.first;
  String? get repository => tagMap['repository']!.first;
  Set<String> get icons => tagMap['icon'] ?? {};
  Set<String> get images => tagMap['image'] ?? {};
  String? get url => tagMap['url']?.firstOrNull;
  Set<String> get pubkeys => tagMap['p'] ?? {};
  Set<String> get tTags => tagMap['t'] ?? {};
  String get githubStars => tagMap['github_stars']!.first;
  String get githubForks => tagMap['github_forks']!.first;
  String get license => tagMap['license']!.first;
  String get aTag => '$kind:$pubkey:${tagMap['d']!.first}';
}
