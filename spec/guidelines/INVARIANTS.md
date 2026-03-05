---
description: Non-negotiable invariants — isolate boundary, SQLite ownership, relay pool, query resolution
alwaysApply: true
---

# purplebase — Invariants

These are non-negotiable. Violating any invariant is a bug — no tradeoffs or exceptions.

## Isolate Boundary

- The relay pool (`RelayPool`) runs exclusively in the background isolate. It must never be instantiated or called from the main isolate.
- SQLite (`Database`) is owned exclusively by the main isolate. The background isolate must never open or write to the database directly.
- All cross-isolate communication goes through `IsolateBridge` (typed `SendPort`/`ReceivePort`). Direct shared-memory access between isolates is forbidden.
- The background isolate sends raw `Map<String, dynamic>` events back to the main isolate via `QueryResultNotification`. The main isolate is responsible for writing them to SQLite and constructing typed models.

## SQLite as Single Source of Truth

- Every model surfaced to the app must have been written to SQLite first. Relay events are never emitted directly to consumers — they go through `save → SQLite → InternalStorageData → querySync → emit`.
- `querySync` is the only synchronous read path and must always read from SQLite (or `AuthorKindCache` for hot paths). It must never block on network or isolate communication.
- All SQLite writes within a single `QueryResultNotification` batch must be committed in a single transaction. Partial writes are a bug.
- `obliterate()` deletes the database file and all associated state. After `obliterate()`, the storage must be re-initialized before use.

## Query Resolution

- Every query MUST resolve within a bounded time. The relay pool enforces this via `eoseTimeout` (absolute) and `eoseGraceWindow` (after first EOSE). Neither timer may be disabled.
- If all relays for a subscription fail (max retries exceeded), the subscription transitions to `RelaySubPhase.failed` and the query resolves with whatever data is in the buffer — it does not hang.
- A relay error or timeout for one subscription must not affect other active subscriptions.

## Relay Pool

- Subscriptions are deduplicated at the pool level via `RequestTracker`. An identical streaming subscription (same filters) is never opened twice.
- `since` is applied to ALL REQ sends (initial and reconnect), not only streaming reconnections. This prevents re-fetching already-seen events.
- Reconnect uses exponential backoff. After `PoolConstants.maxRetries` failed attempts, the relay transitions to `RelaySubPhase.failed` and stops retrying automatically.
- Zombie connections (no activity beyond `pingIdleThreshold`) are detected via a ping REQ and disconnected if no response arrives within `relayTimeout`.
- When offline (`setConnectivity(false)`), no new connections are attempted and all reconnect timers are cancelled. On coming back online, all subscriptions reconnect automatically.

## Publish

- `publish()` waits for an OK message from each target relay. If no OK arrives within `responseTimeout`, the result is recorded as rejected (timeout) — the caller always gets a `PublishResponse`, never a hanging future.
- Publish failures for one relay do not prevent publishing to other relays in the same call.

## Heartbeat

- The main isolate sends a `HeartbeatMessage` to the background isolate on a fixed interval. If the isolate is disposed, heartbeats are silently dropped. The heartbeat must never throw or crash the isolate.

## Error Handling

- All errors must be wrapped with context (subscription ID, relay URL, operation type).
- Errors must propagate to `StorageState` as `StorageError` — never swallowed silently.
- A crash in the background isolate must be surfaced as a `StorageError`; the main isolate must not crash as a result.
