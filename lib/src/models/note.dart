part of purplebase;

class Note extends ParameterizableReplaceableEvent<Note> with _NoteMixin {
  Note.fromJson(super.map) : super.fromJson();

  @override
  EventConstructor<Note> get constructor => Note.fromJson;
}

mixin _NoteMixin on EventBase {
  @override
  int get kind => 1;

  String? get name => event.tags['name']?.firstOrNull;
  String? get repository => event.tags['repository']?.firstOrNull;
  String get description => event.content;
  String? get url => event.tags['url']?.firstOrNull;
  Set<String> get icons => event.tags['icon']?.toSet() ?? {};
  Set<String> get images => event.tags['image']?.toSet() ?? {};
}

class PartialNote
    extends ParameterizableReplaceablePartialEvent<PartialNote, Note>
    with _NoteMixin {
  set description(String value) => event.content = value;
  set name(String? value) => event.setTag('name', value);
  set repository(String? value) => event.setTag('repository', value);
  set url(String? value) => event.setTag('url', value);
  set icon(String value) => event.setTag('icon', value);
  set image(String value) => event.setTag('image', value);
}

// class BaseApp extends BaseEvent<BaseApp>
//     with ParameterizableReplaceableEvent<BaseApp> {
//   BaseApp({
//     String? content,
//     DateTime? createdAt,
//     Set<String>? pubkeys,
//     Set<String>? zapTags,
//     Set<String>? tags,
//     String? identifier,
//     String? name,
//     String? summary,
//     String? repository,
//     Set<String>? icons,
//     Set<String>? images,
//     String? url,
//     String? license,
//     Set<String>? platforms,
//     Set<ReplaceableEventLink>? linkedReplaceableEvents,
//   }) : super(
//           content: content,
//           createdAt: createdAt,
//           pubkeys: pubkeys,
//           zapTags: zapTags,
//           tags: tags,
//           identifier: identifier,
//           linkedReplaceableEvents: linkedReplaceableEvents,
//           additionalEventTags: {
//             ...?icons?.map((i) => ('icon', i)),
//             ...?images?.map((i) => ('image', i)),
//             ('name', name),
//             ('summary', summary),
//             ('repository', repository),
//             ('url', url),
//             ('license', license),
//             ...?platforms?.map((i) => ('f', i)),
//           },
//         );

//   BaseApp.fromJson(super.map) : super.fromJson();

//   BaseApp copyWith({
//     DateTime? createdAt,
//     String? content,
//     Set<String>? pubkeys,
//     Set<String>? zapTags,
//     Set<String>? tags,
//     String? identifier,
//     String? name,
//     String? repository,
//     Set<String>? icons,
//     Set<String>? images,
//     String? url,
//     String? license,
//     Set<String>? platforms,
//     Set<ReplaceableEventLink>? linkedReplaceableEvents,
//   }) {
//     return BaseApp(
//       createdAt: createdAt ?? this.createdAt,
//       content: content ?? this.content,
//       pubkeys: pubkeys ?? this.pubkeys,
//       zapTags: zapTags ?? this.zapTags,
//       tags: tags ?? this.tags,
//       identifier: identifier ?? this.identifier,
//       name: name ?? this.name,
//       repository: repository ?? this.repository,
//       icons: icons ?? this.icons,
//       images: images ?? this.images,
//       url: url ?? this.url,
//       license: license ?? this.license,
//       platforms: platforms ?? this.platforms,
//       linkedReplaceableEvents:
//           linkedReplaceableEvents ?? this.linkedReplaceableEvents,
//     );
//   }

//   String? get name => tagMap['name']?.firstOrNull;
//   String? get summary => tagMap['summary']?.firstOrNull;
//   String? get repository => tagMap['repository']?.firstOrNull;
//   Set<String> get icons => tagMap['icon'] ?? {};
//   Set<String> get images => tagMap['image'] ?? {};
//   String? get url => tagMap['url']?.firstOrNull;
//   String? get license => tagMap['license']?.firstOrNull;
//   Set<String> get platforms => tagMap['f'] ?? {};
// }
