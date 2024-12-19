part of purplebase;

class BaseDirectMessage extends BaseEvent<BaseDirectMessage> {
  BaseDirectMessage({
    required String content,
    required String receiver,
  }) : super(
          content: content,
          additionalEventTags: {('p', receiver.hexKey)},
        );

  BaseDirectMessage.fromJson(super.map) : super.fromJson();

  BaseDirectMessage copyWith({
    String? content,
  }) {
    return BaseDirectMessage(
      content: content ?? this.content,
      receiver: receiver,
    );
  }

  String get receiver => tagMap['p']!.first.npub;
}
