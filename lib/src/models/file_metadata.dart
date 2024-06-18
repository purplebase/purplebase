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
  int? get size => tagMap['size']?.firstOrNull.toInt();
  String? get version => tagMap['version']?.firstOrNull;
  int? get versionCode => tagMap['version_code']?.firstOrNull.toInt();
  String? get repository => tagMap['repository']?.firstOrNull;
  Set<String> get architectures => tagMap['arch'] ?? {};
  Set<String> get pubkeys => tagMap['p'] ?? {};
  String? get apkSignatureHash => tagMap['apk_signature_hash']?.firstOrNull;
}

extension on String? {
  int? toInt() {
    return this == null ? null : int.tryParse(this!);
  }
}
