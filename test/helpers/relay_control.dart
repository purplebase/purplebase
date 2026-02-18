import 'dart:convert';
import 'dart:io';

/// Helper for managing test-relay processes.
///
/// Wraps the Go test-relay binary with helpers for:
/// - Starting with configurable flags (slowness, reject-events, etc.)
/// - SIGUSR1 to wipe all events between tests
/// - Clean shutdown
class TestRelayProcess {
  final Process _process;
  final int port;

  TestRelayProcess._(this._process, this.port);

  /// Start a test-relay on [port] with optional [flags].
  ///
  /// Supported flags: `--slowness`, `--reject-events`, `--disconnect-after-n`,
  /// `--eose-delay`, `--send-closed-after-n`, `--closed-reason`.
  static Future<TestRelayProcess> start(int port,
      {List<String> flags = const []}) async {
    final process = await Process.start(
      'test/support/test-relay',
      ['-port', port.toString(), ...flags],
    );

    process.stdout.transform(utf8.decoder).listen((_) {});
    process.stderr.transform(utf8.decoder).listen((_) {});

    await Future.delayed(Duration(milliseconds: 500));
    return TestRelayProcess._(process, port);
  }

  /// Wipe all stored events via SIGUSR1.
  Future<void> wipe() async {
    _process.kill(ProcessSignal.sigusr1);
    await Future.delayed(Duration(milliseconds: 50));
  }

  /// Kill the relay process.
  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
  }

  /// Access the underlying [Process] (for fixture compatibility).
  Process get process => _process;
}
