part of purplebase;

class FileMetadata = RegularEvent<FileMetadata> with FileMetadataMixin;

class PartialFileMetadata = RegularPartialEvent<FileMetadata>
    with FileMetadataMixin, PartialFileMetadataMixin;

mixin FileMetadataMixin on EventBase {
  Set<String> get urls => event.getTagSet('url');
  String? get mimeType => event.getTag('m');
  String? get hash => event.getTag('x');
  int? get size => event.getTag('size').toInt();
  String? get version => event.getTag('version');
  String? get repository => event.getTag('repository');
  Set<String> get platforms => event.getTagSet('f');
}

mixin PartialFileMetadataMixin on PartialEventBase {}

// class BaseFileMetadata extends BaseEvent<BaseFileMetadata> {
//   BaseFileMetadata({
//     DateTime? createdAt,
//     String? content,
//     Set<String>? pubkeys,
//     Set<String>? zapTags,
//     Set<String>? tags,
//     Set<String>? urls,
//     String? mimeType,
//     String? hash,
//     int? size,
//     String? version,
//     String? repository,
//     Set<String>? platforms,
//     Set<(String, dynamic)>? additionalEventTags,
//   }) : super(
//           content: content,
//           additionalEventTags: {
//             ...?additionalEventTags,
//             ...?urls?.map((u) => ('url', u)),
//             ('m', mimeType),
//             ('x', hash),
//             ('size', size?.toString()),
//             ('version', version),
//             ('repository', repository),
//             ...?platforms?.map((p) => ('f', p)),
//           },
//           createdAt: createdAt,
//           pubkeys: pubkeys,
//           zapTags: zapTags,
//         );

//   BaseFileMetadata.fromJson(Map<String, dynamic> map) : super.fromJson(map);

//   BaseFileMetadata copyWith({
//     DateTime? createdAt,
//     String? content,
//     Set<String>? pubkeys,
//     Set<String>? zapTags,
//     Set<String>? tags,
//     Set<String>? urls,
//     String? mimeType,
//     String? hash,
//     int? size,
//     String? version,
//     String? repository,
//     Set<String>? platforms,
//     Set<(String, dynamic)>? additionalEventTags,
//   }) {
//     return BaseFileMetadata(
//       createdAt: createdAt ?? this.createdAt,
//       content: content ?? this.content,
//       pubkeys: pubkeys ?? this.pubkeys,
//       zapTags: zapTags ?? this.zapTags,
//       tags: tags ?? this.tags,
//       urls: urls ?? this.urls,
//       mimeType: mimeType ?? this.mimeType,
//       hash: hash ?? this.hash,
//       size: size ?? this.size,
//       version: version ?? this.version,
//       repository: repository ?? this.repository,
//       platforms: platforms ?? this.platforms,
//       additionalEventTags: additionalEventTags ?? this.additionalEventTags,
//     );
//   }

//   Set<String> get urls => tagMap['url'] ?? {};
//   String? get mimeType => tagMap['m']?.firstOrNull;
//   String? get hash => tagMap['x']?.firstOrNull;
//   int? get size => tagMap['size']?.firstOrNull.toInt();
//   String? get version => tagMap['version']?.firstOrNull;
//   String? get repository => tagMap['repository']?.firstOrNull;
//   Set<String> get platforms => tagMap['f'] ?? {};
// }
