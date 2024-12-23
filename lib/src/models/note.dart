part of purplebase;

mixin _NoteMixin on EventBase {}

class Note = RegularEvent<Note> with _NoteMixin;

class PartialNote extends RegularPartialEvent<Note> with _NoteMixin {}
