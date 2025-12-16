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
| `maxRetries` | 20 | Before marking relay as failed |

## Query Modes

| Mode | `stream` | Returns | Behavior |
|------|----------|---------|----------|
| Blocking | `false` | `Future<List<Event>>` | Waits for all relays, then returns |
| Streaming | `true` | `[]` immediately | Events arrive via callbacks |

```dart
// Blocking: waits for all relays to respond
final events = await storage.query<Note>(
  req,
  source: RemoteSource(relays: 'default', stream: false),
);

// Streaming: returns immediately, events come via notification
await storage.query<Note>(
  req,
  source: RemoteSource(relays: 'default', stream: true),
);
```

### Timeout Handling

When relays don't respond within `responseTimeout`:
- **Blocking queries:** Return partial results and auto-cleanup
- **Streaming queries:** Continue with responding relays

## Architecture

- **Background Isolate** - SQLite + WebSocket pool run off the UI thread
- **Single Source of Truth** - `PoolState` contains all subscription and relay state
- **Per-Subscription Relay Tracking** - Each subscription tracks its relays independently
- **Auto-Reconnect** - Exponential backoff with retry limit per relay
- **ensureConnected()** - Immediate reconnection for app lifecycle events
- **Ping Health Checks** - `limit:0` requests detect zombie connections (55s idle threshold)
- **Event Batching** - Cross-relay deduplication with configurable flush window
- **No Resource Leaks** - Timeouts always clean up blocking subscriptions

## Testing

```bash
dart test
```

## License

MIT
