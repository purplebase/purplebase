import 'package:purplebase/purplebase.dart' hide Release;

class Release = ParameterizableReplaceableEvent<Release> with ReleaseMixin;

class PartialRelease = ParameterizableReplaceablePartialEvent<Release>
    with ReleaseMixin, MutableReleaseMixin;

mixin ReleaseMixin on EventBase {
  String get releaseNotes => event.content;
}

mixin MutableReleaseMixin on PartialEventBase {
  set releaseNotes(String value) => event.content = value;
}
