import 'package:purplebase/purplebase.dart' hide Release;

class Release = ParameterizableReplaceableEvent<Release> with ReleaseMixin;

class PartialRelease = ParameterizableReplaceablePartialEvent<Release>
    with ReleaseMixin, PartialReleaseMixin;

mixin ReleaseMixin on EventBase {
  String get releaseNotes => event.content;
}

mixin PartialReleaseMixin on PartialEventBase {
  set releaseNotes(String value) => event.content = value;
}
