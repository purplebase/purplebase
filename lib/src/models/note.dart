part of purplebase;

mixin _NoteMixin on EventBase {
  @override
  int get kind => 1;
}

class Note = RegularEvent<Note> with _NoteMixin;

class PartialNote extends RegularPartialEvent<Note> with _NoteMixin {}
