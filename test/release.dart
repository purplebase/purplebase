import 'package:purplebase/purplebase.dart' hide Release;

class Release = ParameterizableReplaceableEvent<Release> with ReleaseMixin;

class PartialRelease = ParameterizableReplaceablePartialEvent<Release>
    with ReleaseMixin, PartialReleaseMixin;

mixin ReleaseMixin on EventBase<Release> {
  String get releaseNotes => event.content;
}

mixin PartialReleaseMixin on PartialEventBase<Release> {
  set releaseNotes(String value) => event.content = value;
}
