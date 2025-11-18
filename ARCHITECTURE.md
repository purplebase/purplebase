# Purplebase Architecture

## WebSocket Pool

### Overview

The WebSocket pool uses self-managing relay agents with clean separation of concerns. Each relay connection is independent and handles its own lifecycle automatically.

### Core Components

#### 1. RelayAgent (`lib/src/pool/connection/relay_agent.dart`)

**Purpose:** Self-contained connection manager for a single relay

**Responsibilities:**
- Manages WebSocket connection lifecycle (connect, reconnect, disconnect)
- Auto-reconnects with exponential backoff (100ms → 30s)
- Handles subscriptions and publishes for this relay
- Notifies coordinator via strongly-typed callbacks (no shared mutable state)

**Key Features:**
- **Self-managing:** Runs own reconnection loop when subscriptions exist
- **Explicit state machine:** `Connecting → Connected → Disconnected`
- **Backoff aware:** Maintains `nextReconnectAt`, `reconnectAttempts`, `lastError`
- **Force reconnect hook:** `checkAndReconnect(force: true)` ignores backoff windows, used by `ensureConnected()`

**API:**
```dart
await agent.subscribe(subId, filters);  // Starts connection if needed
await agent.publish(event);              // Returns PublishResult
agent.unsubscribe(subId);                // Stops reconnection if no subs remain
```

#### 2. SubscriptionBuffer (`lib/src/pool/subscription/subscription_buffer.dart`)

**Purpose:** Event batching and deduplication for a subscription

**Responsibilities:**
- Deduplicates events across relays (by event ID)
- Batches events with configurable window (50ms default)
- Tracks EOSE from all target relays
- Provides Future for one-shot queries, flushes for streaming

**Two Modes:**
- **One-shot queries:** Buffers until all EOSE received, returns full list
- **Streaming subscriptions:** Flushes batches periodically as events arrive

#### 3. WebSocketPool (`lib/src/pool/websocket_pool.dart`)

**Purpose:** Thin coordinator that routes requests to agents

**Responsibilities:**
- Creates RelayAgents lazily (one per normalized URL)
- Routes subscription/publish requests to appropriate agents
- Manages SubscriptionBuffers for cross-relay deduplication
- Aggregates agent states into PoolState for UI / health metrics
- Exposes `performHealthCheck({bool force = false})` for both scheduled heartbeats and foreground `ensureConnected()` sweeps

### Data Flow

#### Query Operation

```
User calls pool.query(req, relayUrls)
  ↓
Pool creates SubscriptionBuffer
  ↓
Pool gets/creates RelayAgent for each URL
  ↓
Pool calls agent.subscribe(subId, filters)
  ↓
Agent connects (if not connected) and sends REQ
  ↓
Agent receives EVENT messages
  ↓
Agent calls onEvent(relayUrl, subId, event) callback
  ↓
Pool adds events to SubscriptionBuffer (deduplicates)
  ↓
Agent receives EOSE
  ↓
Agent calls onEose(relayUrl, subId) callback
  ↓
Buffer marks EOSE for this relay
  ↓
When all EOSEs received, buffer flushes
  ↓
Events emitted via RelayEventNotifier
  ↓
Query completes and returns events
```

#### Publish Operation

```
User calls pool.publish(events, relayUrls)
  ↓
Pool gets/creates RelayAgent for each URL
  ↓
Pool calls agent.publish(event) for each event
  ↓
Agent connects (if not connected)
  ↓
Agent sends EVENT message
  ↓
Agent receives OK response
  ↓
Agent completes PublishResult future
  ↓
Pool aggregates results from all agents
  ↓
Returns PublishRelayResponse
```

### Design Benefits

- **Self-managing:** Each agent handles its own connection lifecycle independently
- **Simple coordination:** Callbacks instead of shared mutable state
- **Automatic reconnection:** Exponential backoff built into each agent
- **Explicit reconnect control:** Foreground apps can call `ensureConnected()` to cancel backoff delays instantly
- **Clean batching:** SubscriptionBuffer handles deduplication and timing
- **Testable:** Agents can be tested in isolation from the coordinator

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
- EOSE handling and batching
- Publish operations and OK responses
- Subscription lifecycle
- Pool state tracking
- Integration tests with local relay server

### Performance Characteristics

- **Efficient memory:** Single source of truth per agent, no redundant state tracking
- **Lazy connection:** Agents created on-demand, only when needed
- **Low latency:** Direct callback path from agents to coordinator
- **Smart batching:** Two-level batching (per-agent + cross-relay deduplication)

### Future Improvements

1. **Connection pooling:** Reuse agents across subscription lifecycles
2. **Smart relay selection:** Prioritize responsive relays
3. **Event caching:** Avoid re-fetching seen events
4. **Adaptive backoff:** Learn relay response times / failure rates
5. **Health scoring:** Track relay reliability metrics for UI

