# purplebase

A powerful local-first nostr client framework written in Dart with built-in WebSocket pool management and background isolate support.

Reference implementation of [models](https://github.com/purplebase/models).

## Features

- 🔄 **Local-First Architecture** - SQLite-backed storage with background isolate processing
- 🌐 **Smart WebSocket Pool** - Automatic reconnection with exponential backoff
- 📡 **Ping-Based Health Checks** - Detects zombie connections via `limit:0` requests
- 🎯 **Event Deduplication** - Intelligent handling of events from multiple relays
- 📊 **Unified State** - Connection status, request state, and debug info in one place
- ⚙️ **Configurable Batching** - Low-latency streaming with tunable flush windows

## Quick Start

```dart
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';

// Configure
final config = StorageConfiguration(
  databasePath: 'myapp.db',
  defaultRelays: {
    'default': {'wss://relay.damus.io', 'wss://relay.nostr.band'},
  },
  defaultQuerySource: const LocalAndRemoteSource(
    relays: 'default',
    stream: false,
  ),
);

// Initialize
final container = ProviderContainer();
await container.read(initializationProvider(config).future);

// Query
final notes = await container.read(storageNotifierProvider.notifier).query<Note>(
  RequestFilter(kinds: {1}, limit: 20).toRequest(),
  source: RemoteSource(relays: 'default'),
);
```

## App Lifecycle (Recommended)

Call `ensureConnected()` when your app resumes to immediately reconnect:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    ref.read(storageNotifierProvider.notifier).ensureConnected();
  }
}
```

This triggers ping-based health checks and reconnects zombie connections.

## Pool State

Access connection and request state through `poolStateProvider`:

```dart
final poolState = ref.watch(poolStateProvider);

// Check relay status
final relay = poolState?.relays['wss://relay.damus.io'];
print('Status: ${relay?.status}');        // connected, connecting, disconnected
print('Attempts: ${relay?.reconnectAttempts}');
print('Error: ${relay?.error}');

// Check request status
final request = poolState?.requests[subscriptionId];
print('EOSE: ${request?.eoseReceived.length}/${request?.targetRelays.length}');
print('Events: ${request?.eventCount}');
print('Status: ${request?.statusText}');  // "2/3 EOSE" or "streaming"

// Convenience getters
print('Connected: ${poolState?.connectedCount}');
print('Disconnected: ${poolState?.disconnectedCount}');

// Debug info (merged from old DebugNotifier)
print('Last change: ${poolState?.lastChange}');
```

## State Types

### PoolState
```dart
class PoolState {
  final Map<String, RelayState> relays;     // Per-relay connection state
  final Map<String, RequestState> requests; // Per-subscription state
  final DateTime timestamp;
  final String? lastChange;                  // Debug: "Connected to wss://..."
}
```

### ConnectionStatus
```dart
enum ConnectionStatus { disconnected, connecting, connected }
```

### RelayState
```dart
class RelayState {
  final String url;
  final ConnectionStatus status;
  final int reconnectAttempts;
  final String? error;
  final DateTime? lastActivityAt;
  final DateTime statusChangedAt;
}
```

### RequestState
```dart
class RequestState {
  final String subscriptionId;
  final List<Map<String, dynamic>> filters;
  final Set<String> targetRelays;
  final Set<String> eoseReceived;           // Which relays sent EOSE
  final bool isStreaming;
  final int eventCount;
  final DateTime startedAt;
  
  String get statusText;                     // "2/3 EOSE" or "streaming"
  bool get allEoseReceived;
}
```

## Configuration

```dart
StorageConfiguration(
  databasePath: 'myapp.db',                          // null for in-memory
  defaultRelays: {'default': {'wss://relay.com'}},
  defaultQuerySource: LocalAndRemoteSource(relays: 'default', stream: false),
  responseTimeout: Duration(seconds: 15),
  streamingBufferWindow: Duration(milliseconds: 100),
)
```

## Architecture

- **Background Isolate** - SQLite + WebSocket pool run off the UI thread
- **Unified State** - `poolStateProvider` for connections, requests, and debug info
- **Auto-Reconnect** - Exponential backoff + `ensureConnected()` for app lifecycle
- **Ping Health Checks** - `limit:0` requests detect zombie connections
- **Event Batching** - Cross-relay deduplication with configurable flush window

## Testing

```bash
dart test
```

## License

MIT
