/// Test constants and fixtures for purplebase tests

/// Test relay ports - unique per test file for parallel execution
class TestPorts {
  static const connection = 3335;
  static const subscription = 3336;
  static const state = 3337;
  static const query = 3338;
  static const publish = 3339;
  static const integration = 3340;
  static const reconnection = 3341;
  static const buffer = 3342;
  static const closeSubscriptions = 3343;
  static const isolateRemote = 7078;
}

/// Test relay URLs derived from ports
class TestRelays {
  static String url(int port) => 'ws://localhost:$port';
  static String get connection => url(TestPorts.connection);
  static String get subscription => url(TestPorts.subscription);
  static String get state => url(TestPorts.state);
  static String get query => url(TestPorts.query);
  static String get publish => url(TestPorts.publish);
  static String get integration => url(TestPorts.integration);
  static String get reconnection => url(TestPorts.reconnection);
  static String get closeSubscriptions => url(TestPorts.closeSubscriptions);
  static String get isolateRemote =>
      'ws://127.0.0.1:${TestPorts.isolateRemote}';

  /// Offline relay for testing failure scenarios
  static const offline = 'ws://localhost:65534';

  /// Invalid URL for testing error handling
  static const invalid = 'invalid-url';
}

/// Test signing keys
class TestKeys {
  /// Standard test private key (deterministic for reproducible tests)
  static const privateKey =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
}

/// Common test pubkeys (reuse from models package when available)
class TestPubkeys {
  static const niel =
      'a9434ee165ed01b286becfc2771ef1705d3537d051b387288898cc00d5c885be';
  static const verbiricha =
      '7fa56f5d6962ab1e3cd424e758c3002b8665f7b0d8dcee9fe9e288d7751ac194';
  static const franzap =
      '726a1e261cc6474674e8285e3951b3bb139be9a773d1acf49dc868db861a1c11';
}
