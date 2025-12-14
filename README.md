# purplebase

A powerful local-first nostr client framework written in Dart with built-in WebSocket pool management and background isolate support.

Reference implementation of [models](https://github.com/purplebase/models).

## Features

- 🔄 **Local-First Architecture** - SQLite-backed storage with background isolate processing
- 🌐 **Smart WebSocket Pool** - Automatic reconnection with exponential backoff
- 📡 **Ping-Based Health Checks** - Detects zombie connections via `limit:0` requests
- 🎯 **Event Deduplication** - Intelligent handling of events from multiple relays
- 📊 **Unified State** - Single source of truth for subscriptions and relay state
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

This resets backoff timers and triggers immediate reconnection for disconnected relays.

## Pool State

Access subscription and relay state through `poolStateProvider`:

```dart
final poolState = ref.watch(poolStateProvider);

// Check subscription status
final sub = poolState?.subscriptions[subscriptionId];
print('Active relays: ${sub?.activeRelayCount}/${sub?.totalRelayCount}');
print('Status: ${sub?.statusText}');  // "2/3 relays" or "failed"
print('Stream mode: ${sub?.stream}');

// Check per-relay state within a subscription
final relay = sub?.relays['wss://relay.damus.io'];
print('Phase: ${relay?.phase}');        // disconnected, connecting, loading, streaming, waiting, failed
print('Attempts: ${relay?.reconnectAttempts}');
print('Last event: ${relay?.lastEventAt}');
print('Error: ${relay?.lastError}');

// View logs (max 200 entries)
for (final log in poolState?.logs ?? []) {
  print('[${log.level}] ${log.message}');
}
```

## State Types

### PoolState
```dart
class PoolState {
  final Map<String, Subscription> subscriptions;  // Per-subscription state
  final List<LogEntry> logs;                      // Activity log (max 200)
}
```

### Subscription
```dart
class Subscription {
  final String id;
  final Request request;
  final bool stream;                              // User intent: keep alive
  final DateTime startedAt;
  final Map<String, RelaySubState> relays;        // Per-relay state
  
  int get activeRelayCount;                       // Relays in streaming phase
  int get totalRelayCount;
  bool get allFailed;
  bool get hasActiveRelay;
  bool get allEoseReceived;
  String get statusText;                          // "2/3 relays" or "failed"
}
```

### RelaySubPhase
```dart
enum RelaySubPhase {
  disconnected,   // Not connected
  connecting,     // Attempting to connect
  loading,        // Connected, waiting for EOSE
  streaming,      // Connected, EOSE received, receiving events
  waiting,        // Backing off before retry
  failed,         // Max retries exceeded
}
```

### RelaySubState
```dart
class RelaySubState {
  final RelaySubPhase phase;
  final DateTime? lastEventAt;
  final int reconnectAttempts;
  final String? lastError;
}
```

### LogEntry
```dart
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;           // info, warning, error
  final String message;
  final String? subscriptionId;
  final String? relayUrl;
  final Exception? exception;
}
```

## Configuration

```dart
StorageConfiguration(
  databasePath: 'myapp.db',                          // null for in-memory
  defaultRelays: {'default': {'wss://relay.com'}},
  defaultQuerySource: LocalAndRemoteSource(relays: 'default', stream: false),
  responseTimeout: Duration(seconds: 15),            // EOSE and publish timeout
  streamingBufferWindow: Duration(milliseconds: 100), // Event batching window
)
```

## Pool Constants

The pool uses these timing constants (not configurable):

| Constant | Value | Description |
|----------|-------|-------------|
| `relayTimeout` | 5s | Connection and ping timeout |
| `maxReconnectDelay` | 30s | Maximum backoff delay |
| `initialReconnectDelay` | 100ms | First retry delay |
| `pingIdleThreshold` | 55s | Ping if idle this long |
| `healthCheckInterval` | 60s | Heartbeat frequency |
| `maxRetries` | 5 | Before marking relay as failed |

## Architecture

- **Background Isolate** - SQLite + WebSocket pool run off the UI thread
- **Single Source of Truth** - `PoolState` contains all subscription and relay state
- **Per-Subscription Relay Tracking** - Each subscription tracks its relays independently
- **Auto-Reconnect** - Exponential backoff with 5 retry limit per relay
- **ensureConnected()** - Immediate reconnection for app lifecycle events
- **Ping Health Checks** - `limit:0` requests detect zombie connections (55s idle threshold)
- **Event Batching** - Cross-relay deduplication with configurable flush window

## Testing

```bash
dart test
```

## License

MIT
