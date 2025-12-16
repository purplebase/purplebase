# Purplebase Architecture

## WebSocket Pool

### Overview

The WebSocket pool (`RelayPool`) is the single source of truth for all relay state. It handles connections, subscriptions, events, and publishes with clean separation between blocking and streaming queries.

### Core Components

#### 1. RelayPool (`lib/src/pool/pool.dart`)

**Purpose:** Central coordinator for all relay operations

**Responsibilities:**
- Manages WebSocket connections via `RelaySocket` wrappers
- Routes subscriptions to appropriate relays
- Buffers and deduplicates events via `_EventBuffer`
- Handles EOSE (End of Stored Events) timing and timeouts
- Auto-reconnects with exponential backoff
- Emits unified `PoolState` for UI / health metrics

**Query Modes:**

| Mode | `stream` | Returns | EOSE Behavior | Lifecycle |
|------|----------|---------|---------------|-----------|
| Blocking | `false` | `Future<List<Event>>` | Wait for all relays, then complete | Auto-unsubscribe after EOSE/timeout |
| Streaming | `true` | `[]` immediately | Flush progressively on each EOSE | Stays open until manual cancel |

**API:**
```dart
// Blocking query - waits for all EOSEs, returns events
final events = await pool.query(req, source: RemoteSource(stream: false));

// Streaming query - returns immediately, events via callback
pool.query(req, source: RemoteSource(stream: true));

// Unsubscribe
pool.unsubscribe(req);

// Publish
final response = await pool.publish(events, source: source);
```

#### 2. _EventBuffer (internal)

**Purpose:** Per-subscription event batching and deduplication

**Responsibilities:**
- Deduplicates events by ID across relays
- Tracks which relays sent each event
- Handles EOSE reception and flush triggers
- Completes `queryCompleter` for blocking queries

**Two Behaviors Based on `queryCompleter`:**

| `queryCompleter` | Flush Behavior | Use Case |
|------------------|----------------|----------|
| Present | Wait for ALL EOSEs, then flush once | Blocking queries (`stream=false`) |
| Null | Flush progressively on each EOSE | Streaming or fire-and-forget |

#### 3. RelaySocket (`lib/src/pool/connection.dart`)

**Purpose:** Thin WebSocket wrapper with no reconnection logic

**Responsibilities:**
- Connect/disconnect to a single relay
- Send REQ, CLOSE, EVENT messages
- Parse incoming messages and call handlers
- Track last activity time for idle detection

### Data Flow

#### Query Operation (Blocking)

```
User calls pool.query(req, source: RemoteSource(stream: false))
  ↓
Pool creates _EventBuffer with queryCompleter
  ↓
Pool creates Subscription with stream=false
  ↓
Pool connects to each relay and sends REQ
  ↓
Relays send EVENT messages
  ↓
Pool adds events to _EventBuffer (deduplicates)
  ↓
Relays send EOSE
  ↓
Buffer tracks EOSE count
  ↓
When all EOSEs received (or timeout), buffer flushes
  ↓
queryCompleter.complete(events)
  ↓
Pool auto-unsubscribes (closes subscription)
  ↓
Future completes with event list
```

#### Query Operation (Streaming)

```
User calls pool.query(req, source: RemoteSource(stream: true))
  ↓
Pool creates _EventBuffer WITHOUT queryCompleter
  ↓
Pool creates Subscription with stream=true
  ↓
Pool connects to each relay and sends REQ
  ↓
Relays send EVENT messages
  ↓
Pool adds events to _EventBuffer
  ↓
Buffer schedules batch flush (configurable window)
  ↓
Events emitted via onEvents callback
  ↓
Relays send EOSE
  ↓
Buffer flushes any remaining events on each EOSE
  ↓
Subscription stays open for live events
  ↓
User must call pool.unsubscribe(req) to close
```

#### Partial EOSE / Timeout Handling

When not all relays respond with EOSE within `responseTimeout`:

| Query Type | Behavior |
|------------|----------|
| Blocking (`stream=false`) | Timeout → flush partial results → complete Future → auto-unsubscribe |
| Streaming (`stream=true`) | Timeout → flush buffer → log warning → subscription stays open |

This ensures no resource leaks for blocking queries even when relays are unresponsive.

### State Model

```dart
// Pool-level state
PoolState {
  subscriptions: Map<String, Subscription>
  logs: List<LogEntry>  // Rolling log, max 200 entries
}

// Per-subscription state
Subscription {
  id: String
  request: Request
  stream: bool
  startedAt: DateTime
  relays: Map<String, RelaySubState>
  
  // Computed properties
  activeRelayCount → int
  totalRelayCount → int
  allEoseReceived → bool
  hasActiveRelay → bool
  allFailed → bool
  statusText → String  // "2/3 relays" or "failed"
}

// Per-relay state within subscription
RelaySubState {
  phase: RelaySubPhase
  lastEventAt: DateTime?
  reconnectAttempts: int
  lastError: String?
  streamingSince: DateTime?  // When EOSE was received
}

// Relay phases
enum RelaySubPhase {
  disconnected  // Not connected
  connecting    // Attempting connection
  loading       // Connected, waiting for EOSE
  streaming     // EOSE received, receiving live events
  waiting       // Backing off before retry
  failed        // Max retries exceeded
}
```

### Accessing Pool State

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

### Event Filtering

Events can be filtered before they reach storage using `RemoteSource.eventFilter`. This allows discarding unwanted events at the earliest point in the pipeline.

**Usage:**
```dart
// Filter by content length
final source = RemoteSource(
  relays: {relayUrl},
  stream: true,
  eventFilter: (event) {
    final content = event['content'] as String?;
    return content != null && content.length > 10;
  },
);

// Filter by kind
final source = RemoteSource(
  relays: {relayUrl},
  eventFilter: (event) => event['kind'] == 1,
);

// Complex filtering
final source = RemoteSource(
  relays: {relayUrl},
  eventFilter: (event) =>
    event['kind'] == 1 &&
    !(event['content'] as String?)?.contains('spam') == true,
);
```

**How it works:**
1. Filter is stored per-subscription in `_subscriptionFilters` map
2. Applied in `_handleEvent()` before adding to buffer
3. Events that don't pass (`filter(event) == false`) are silently discarded
4. Filter is cleaned up on `unsubscribe()` and `dispose()`

**Benefits:**
- Reduces storage writes for unwanted events
- Works with both blocking and streaming queries
- Filter logic stays with the query definition

### Design Principles

1. **Single Source of Truth:** `RelayPool` owns all state, emits via `onStateChange`
2. **Discriminate by Intent:**
   - `queryCompleter` → flush behavior (batched vs progressive)
   - `stream` → lifecycle (auto-close vs stay-open)
3. **No Resource Leaks:** Timeout always cleans up blocking queries
4. **Progressive Delivery:** Streaming queries get events as they arrive
5. **Deduplication:** Events deduplicated by ID across all relays
6. **Early Filtering:** Event filters applied before buffering to minimize wasted work

### Package Dependencies

Uses the official `web_socket` package:
- Simple event-based API
- Cross-platform support (including web)
- Well-maintained by Dart team
- Clean disconnect handling

### Testing

The test suite covers:
- Connection management and reconnection
- Event deduplication across relays
- EOSE handling (blocking vs streaming)
- Timeout behavior and cleanup
- Publish operations and OK responses
- Subscription lifecycle
- Pool state tracking
- Event filtering (content, kind, complex predicates)
- Integration tests with local relay server

### Configuration

```dart
StorageConfiguration(
  responseTimeout: Duration(seconds: 15),      // EOSE and publish timeout
  streamingBufferWindow: Duration(milliseconds: 100),  // Event batch window
)
```

### Pool Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `relayTimeout` | 5s | WebSocket connection timeout |
| `maxReconnectDelay` | 30s | Maximum backoff delay |
| `initialReconnectDelay` | 100ms | First retry delay |
| `pingIdleThreshold` | 55s | Ping if no activity |
| `healthCheckInterval` | 60s | Background heartbeat |
| `maxRetries` | 20 | Before marking relay as failed |
| `maxLogEntries` | 200 | Rolling log size |
