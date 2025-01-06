part of purplebase;

mixin _NoteMixin on EventBase<Note> {}

class Note = RegularEvent<Note> with _NoteMixin;

class PartialNote extends RegularPartialEvent<Note> with _NoteMixin {
  PartialNote([String? content]) {
    if (content != null) {
      event.content = content;
    }
  }
}
