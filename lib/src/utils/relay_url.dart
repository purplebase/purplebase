/// Re-export normalizeRelayUrl from the models storage layer.
///
/// This is the canonical URL normalization used throughout purplebase
/// for consistent relay URL handling (scheme, port, trailing slash, etc).
export 'package:models/models.dart' show normalizeRelayUrl;
