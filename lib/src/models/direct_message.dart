part of purplebase;

mixin _DirectMessageMixin on EventBase {
  String get receiver => event.getTag('p')!.npub;
  String get content => event.content;
}

class DirectMessage = RegularEvent<DirectMessage> with _DirectMessageMixin;

class PartialDirectMessage extends RegularPartialEvent<DirectMessage>
    with _DirectMessageMixin {
  PartialDirectMessage({
    required String content,
    required String receiver,
  }) {
    event.content = content;
    event.setTag('p', receiver.hexKey);
  }
}
