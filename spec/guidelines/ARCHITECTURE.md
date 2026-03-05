---
description: Architecture — package layout, dependency rules, key patterns
alwaysApply: true
---

# purplebase — Architecture

## Core Principle

SQLite is the single source of truth; the relay pool (running in a background isolate) writes events into it, and the main isolate reads from it — the UI thread never touches relay I/O.

## Package Layout

```
lib/
├── purplebase.dart              # Barrel export
└── src/
    ├── db/
    │   ├── schema.dart          # SQL DDL — events table, indexes, FTS, migrations
    │   ├── database.dart        # Low-level SQLite helpers (open, execute, transaction)
    │   ├── query_builder.dart   # Translates RequestFilter → SQL WHERE clause + bindings
    │   ├── codec.dart           # JSON ↔ SQLite row serialization/deserialization
    │   └── pruning.dart         # DB maintenance: evict old events, enforce keepMaxModels
    ├── pool/
    │   ├── relay_pool.dart      # RelayPool — manages sockets, subscriptions, EOSE tracking,
    │   │                        #   publish, ping/zombie detection; runs in background isolate
    │   ├── relay_socket.dart    # RelaySocket — single WebSocket connection to one relay
    │   ├── managed_socket.dart  # ManagedSocket — wraps RelaySocket with reconnect state
    │   ├── event_buffer.dart    # EventBuffer — batches incoming events per subscription
    │   ├── request_tracker.dart # RequestTracker — pool-level dedup of identical subscriptions
    │   └── pool_state.dart      # PoolState, RelaySubscription, RelaySubState, RelaySubPhase,
    │                            #   PoolConfiguration, PoolConstants, LogEntry
    ├── isolate/
    │   ├── isolate_entry.dart   # isolateEntryPoint — background isolate main function
    │   ├── isolate_bridge.dart  # IsolateBridge — typed SendPort/ReceivePort wrapper
    │   └── messages.dart        # IsolateOperation, IsolateResponse, QueryResultNotification,
    │                            #   PoolStateNotification, HeartbeatMessage
    ├── notifiers/
    │   └── pool_state_notifier.dart  # poolStateProvider — exposes PoolState to UI
    └── storage/
        ├── purplebase_storage.dart   # PurplebaseStorageNotifier — implements StorageNotifier;
        │                             #   owns the DB, spawns the isolate, drives the bridge
        ├── cache.dart                # AuthorKindCache — hot in-memory cache for querySync
        └── connectivity.dart        # ConnectivityNotifier implementation (platform-aware)
```

## Dependency Rules

- `purplebase` depends on `models` for all type definitions and the `StorageNotifier` contract. It must not redefine any model types.
- `src/pool/` has **no** dependency on `src/db/` — the pool only produces raw `Map<String, dynamic>` events; the main isolate writes them to SQLite.
- `src/isolate/` has **no** dependency on `src/db/` or `src/pool/` directly — it only knows `messages.dart` and orchestrates via message passing.
- `src/db/` has **no** dependency on `src/pool/` or `src/isolate/`.
- `PurplebaseStorageNotifier` is the only place that wires all layers together.
- No file in `purplebase` may import Flutter widgets or platform channels directly — use `models`' `ConnectivityNotifier` abstraction.

## Key Patterns

### Initialization

```dart
// In your app's Riverpod override:
storageNotifierProvider.overrideWith(PurplebaseStorageNotifier.new)

// Then initialize once:
await ref.read(storageNotifierProvider.notifier).initialize(
  StorageConfiguration(
    databasePath: 'app.db',
    defaultRelays: {'social': {'wss://relay.damus.io', 'wss://nos.lol'}},
  ),
);
```

### Isolate message flow

```
Main isolate                          Background isolate
─────────────────────────────────     ──────────────────────────────────
PurplebaseStorageNotifier
  │ IsolateBridge.send(QueryOp)  ──►  isolateEntryPoint
  │                                     RelayPool.query(req, source)
  │                                       ↓ events arrive via WebSocket
  │                                     onEvents callback
  │                                       ↓
  │  ◄── QueryResultNotification ──     sendPort.send(notification)
  │
  │ receives savedIds
  │ writes to SQLite (main isolate)
  │ emits InternalStorageData
  ▼
RequestNotifier re-queries SQLite → emits updated List<E>
```

### Heartbeat

`PurplebaseStorageNotifier` sends a `HeartbeatMessage` to the isolate every 30 seconds. The isolate calls `RelayPool.performHealthCheck()`, which pings idle sockets and reconnects stale subscriptions.

### EOSE + grace window algorithm

```
For each subscription:
1. Send REQ to ALL target relays in parallel
2. Collect events as they arrive into EventBuffer
3. On FIRST EOSE from any relay → start grace window timer (default 200 ms)
4. Grace window expires → flush buffered events via onEvents callback
5. Events after grace window → merge via storage layer (streaming)
6. If NO EOSE before absoluteTimeout → flush whatever is buffered (never hang)
```

### Query deduplication

`RequestTracker` keeps a map of active subscription IDs → filter sets. Before opening a new streaming subscription, `RelayPool.query` checks for an exact match. If found, the duplicate is dropped silently (the existing subscription already covers it).

### DB query path

```dart
// querySync (synchronous, main isolate, used by relationships)
final rows = db.select(QueryBuilder.build(req));
return rows.map(codec.decode).map(constructor).toList();

// query (async, triggers remote fetch then re-reads local)
final localResults = querySync(req);
if (localResults.isNotEmpty) emit(localResults);
await bridge.send(QueryOperation(req, source));  // relay fetch
// InternalStorageData notification → re-emit from local
```

### Relay resolution

Relay targets in `RemoteSource.relays` are resolved by `StorageNotifier.resolveRelays` (in `models`) before being passed to the isolate:

| Input | Resolves to |
|---|---|
| `null` | `defaultRelays['default']` (outbox TODO) |
| `'wss://relay.example.com'` | that URL directly |
| `'social'` | active user's `SocialRelayList` (kind 10002), fallback to `defaultRelays['social']` |
| `{'social', 'wss://...'}` | union of both resolutions |

### Pool state observability

```dart
// Watch relay connection state in UI
final poolState = ref.watch(poolStateProvider);
final sub = poolState.subscriptions['sub-note-123456'];
// sub.relays['wss://relay.damus.io'].phase == RelaySubPhase.streaming
```
