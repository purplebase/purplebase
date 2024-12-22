part of purplebase;

mixin _NoteMixin on EventBase {
  @override
  int get kind => 1;
}

class Note extends Event<Note> with _NoteMixin {
  Note.fromJson(super.map) : super.fromJson();

  @override
  EventConstructor<Note> get constructor => Note.fromJson;
}

class PartialNote extends PartialEvent<Note> with _NoteMixin {}
