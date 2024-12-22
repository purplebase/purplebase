part of purplebase;

mixin _NoteMixin on EventBase {
  @override
  int get kind => 1;
}

class Note extends RegularEvent<Note> with _NoteMixin {
  Note.fromJson(super.map) : super.fromJson();

  @override
  EventConstructor<Note> get constructor => Note.fromJson;
}

class PartialNote extends RegularPartialEvent<Note> with _NoteMixin {}
