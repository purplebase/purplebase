part of purplebase;

class BaseFileMetadata extends BaseEvent {
  BaseFileMetadata(
      {super.id,
      super.pubkey,
      super.createdAt,
      super.content,
      super.tags,
      super.signature})
      : super(kind: _kindFor<BaseFileMetadata>());

  Set<String> get urls => tagMap['url'] ?? {};
  String? get mimeType => tagMap['m']?.firstOrNull;
  String? get hash => tagMap['x']?.firstOrNull;
  String? get size => tagMap['size']?.firstOrNull;
  String? get version => tagMap['version']?.firstOrNull;
  String? get repository => tagMap['repository']?.firstOrNull;
  Set<String> get architectures => tagMap['arch'] ?? {};
  Set<String> get pubkeys => tagMap['p'] ?? {};
}
