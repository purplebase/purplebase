# purplebase

A powerful local-first nostr client framework written in Dart with built-in WebSocket pool management, request optimization, and background isolate support.

Reference implementation of [models](https://github.com/purplebase/models).

## Features

- 🔄 **Local-First Architecture** - SQLite-backed storage with background isolate processing
- 🌐 **Smart WebSocket Pool** - Automatic connection management, reconnection, and request optimization
- 📊 **Dual-Channel Notifications** - Separate data and status channels for clean state management
- ⚡ **Request Optimization** - Automatic `since` filter optimization based on last-seen timestamps
- 🎯 **Event Deduplication** - Intelligent handling of events from multiple relays
- 🔍 **Queryable Status** - Real-time visibility into connections, subscriptions, and errors
- 🔌 **Reconnection Tracking** - Monitor relay reconnections, re-sync status, and connection stability per subscription
- 🛡️ **Error Tracking** - Circular buffer for debugging with last 100 errors

## Architecture

Purplebase uses a **two-notifier architecture** to separate data from metadata:

### Data Channel: `RelayEventNotifier`
Emits events and notices received from relays. This is your primary data stream.

### Meta Channel: `PoolStatusNotifier`
Provides queryable status about connections, active subscriptions, and recent errors. Perfect for debugging and UI status displays.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  purplebase:
    git:
      url: https://github.com/purplebase/purplebase.git
```

## Basic Usage

### 1. Initialize Storage

```dart
import 'package:purplebase/purplebase.dart';
import 'package:riverpod/riverpod.dart';

// Configure storage
final config = StorageConfiguration(
  databasePath: 'myapp.db',
  relayGroups: {
    'default': {
      'wss://relay.damus.io',
      'wss://relay.nostr.band',
    },
  },
  defaultRelayGroup: 'default',
  responseTimeout: Duration(seconds: 10),
  streamingBufferWindow: Duration(milliseconds: 100),
);

// Initialize
final container = ProviderContainer();
await container.read(initializationProvider(config).future);
```

### 2. Query Events

```dart
// Query from remote relays
final notes = await container.read(
  storageNotifierProvider.notifier,
).query<Note>(
  RequestFilter(kinds: {1}, limit: 20).toRequest(),
  source: RemoteSource(),
);

// Query from local database
final localNotes = await container.read(
  storageNotifierProvider.notifier,
).query<Note>(
  RequestFilter(kinds: {1}).toRequest(),
  source: LocalSource(),
);
```

### 3. Publish Events

```dart
final signer = container.read(signerProvider);
final note = await PartialNote('Hello Nostr!').signWith(signer);

final response = await container.read(
  storageNotifierProvider.notifier,
).publish(
  {note},
  source: RemoteSource(),
);

// Check which relays accepted
for (final entry in response.results.entries) {
  final eventId = entry.key;
  final states = entry.value;
  for (final state in states) {
    print('${state.relayUrl}: ${state.accepted ? "✓" : "✗"}');
  }
}
```

## Advanced Usage

### Listening to Relay Events (Background Isolate)

The isolate automatically processes events from relays:

```dart
// In your isolate setup (handled internally)
eventNotifier.addListener((event) {
  if (event case EventsReceived(:final response)) {
    // Events are automatically saved to local database
    // You can also forward them to main isolate
    mainSendPort.send(QueryResultMessage(
      request: response.req,
      savedIds: savedIds,
    ));
  }
  
  if (event case NoticeReceived(:final response)) {
    print('NOTICE from ${response.relayUrl}: ${response.message}');
  }
});
```

### Monitoring Pool Status (One Provider, Rich API)

Access via the single `relayStatusProvider`:

```dart
// In your UI widget
final status = ref.watch(relayStatusProvider);

// Use convenience methods on PoolStatus
Widget build(BuildContext context, WidgetRef ref) {
  final status = ref.watch(relayStatusProvider);
  
  if (status == null) return CircularProgressIndicator();
  
  return Column(
    children: [
      // Check specific relay
      if (status.isRelayConnected('wss://relay.damus.io'))
        Text('Damus: Connected ✅')
      else
        Text('Damus: Offline ❌'),
        
      // Show relay state
      Text('State: ${status.getRelayState('wss://relay.damus.io')}'),
      
      // Show when state last changed
      Text('Last change: ${status.getRelayLastStatusChange('wss://relay.damus.io')}'),
      
      // Check if subscription is active
      if (status.isSubscriptionActiveOn(subId, 'wss://relay.damus.io'))
        Text('Subscription active on relay')
      else
        Text('Subscription not active'),
        
      // Show active relay count for subscription
      Text('Active on ${status.getActiveRelayCount(subId)}/${status.subscriptions[subId]?.targetRelays.length} relays'),
      
      // Check if fully active
      if (status.isSubscriptionFullyActive(subId))
        Icon(Icons.check_circle, color: Colors.green)
      else
        Icon(Icons.warning, color: Colors.orange),
        
      // List all connected relays
      Text('Connected: ${status.connectedRelayUrls.join(", ")}'),
      
      // List all disconnected relays
      Text('Disconnected: ${status.disconnectedRelayUrls.join(", ")}'),
      
      // Show errors
      ...status.recentErrors.take(5).map((e) => 
        Text('[${e.timestamp}] ${e.message}')
      ),
    ],
  );
}
```

**Available Methods on `PoolStatus`:**
- `getRelayState(url)` - Get relay connection state
- `isRelayConnected(url)` - Check if relay is connected
- `hasRelayReconnected(url)` - Check if relay has reconnected
- `getRelayLastStatusChange(url)` - Get timestamp of last state change
- `isSubscriptionActiveOn(subId, url)` - Check if subscription active on relay
- `getActiveRelayCount(subId)` - Count active relays for subscription
- `isSubscriptionFullyActive(subId)` - Check if all relays are active
- `connectedRelayUrls` - List of all connected relay URLs
- `disconnectedRelayUrls` - List of all disconnected relay URLs

### Relay Disconnection & Reconnection (Simplified)

When a relay disconnects, here's exactly what happens:

#### **Disconnection:**
1. Relay state → `disconnected`
2. `lastStatusChange` timestamp updated
3. Relay **removed** from all subscriptions' `connectedRelays` sets
4. Request is **no longer active** on that relay
5. WebSocket library starts auto-reconnect with exponential backoff

#### **Reconnection:**
1. Relay state → `reconnected` (marked as reconnected, not initial connection)
2. `lastStatusChange` timestamp updated
3. All subscriptions for this relay **automatically re-sent** with optimized `since` filter
4. Relay **added back** to subscriptions' `connectedRelays` sets
5. Requests become **active again**

#### **Simple Rule:**
> **If relay is in `connectedRelays` → Request is active**  
> **If relay is NOT in `connectedRelays` → Request is NOT active**

No computed status, no complexity. The presence in the list IS the status.

#### **UI Example (Clean API):**

```dart
Widget build(BuildContext context, WidgetRef ref) {
  final status = ref.watch(relayStatusProvider);
  
  if (status == null) return SizedBox();
  
  return ListView(
    children: status.subscriptions.values.map((sub) {
      // Use convenience methods!
      final activeCount = status.getActiveRelayCount(sub.subscriptionId);
      final totalCount = sub.targetRelays.length;
      final isFullyActive = status.isSubscriptionFullyActive(sub.subscriptionId);
      
      Color indicatorColor;
      String statusText;
      
      if (isFullyActive) {
        indicatorColor = Colors.green;
        statusText = 'Live';
      } else if (activeCount > 0) {
        indicatorColor = Colors.orange;
        statusText = '$activeCount/$totalCount';
      } else {
        indicatorColor = Colors.red;
        statusText = 'Offline';
      }
      
      return ListTile(
        leading: Icon(Icons.circle, color: indicatorColor),
        title: Text(sub.subscriptionId),
        subtitle: Text(statusText),
        trailing: sub.resyncing.isNotEmpty
            ? Badge(
                label: Text('${sub.resyncing.length}'),
                child: Icon(Icons.sync),
              )
            : null,
      );
    }).toList(),
  );
}
```

#### **Key Principles:**
- ✅ **Automatic** - Everything happens automatically
- ✅ **Simple** - In `connectedRelays` = active, not in = not active
- ✅ **Accurate** - No computed status that can be stale
- ✅ **Timestamp-tracked** - Every state change has a timestamp
- ✅ **Optimized** - Only fetches new events since last disconnect

### Request Optimization

The pool automatically optimizes requests using `since` filters based on the last seen event timestamp for each relay-request pair:

```dart
// First request - fetches all matching events
final req1 = RequestFilter(kinds: {1}, authors: {myPubkey}).toRequest();
await pool.query(req1);

// Second request - automatically adds since filter
// Only fetches events newer than last seen
final req2 = RequestFilter(kinds: {1}, authors: {myPubkey}).toRequest();
await pool.query(req2); // Optimized!
```

This optimization:
- Reduces bandwidth usage
- Minimizes relay load
- Uses LRU cache (max 1000 entries)
- Per relay-request pair tracking
- **Applied during reconnection** - Reconnected relays only fetch new events

### Streaming Subscriptions

Keep subscriptions active to receive new events as they arrive:

```dart
// Stream mode - subscription stays active
await pool.query(
  RequestFilter(kinds: {1}).toRequest(),
  source: RemoteSource(stream: true),
);

// Events continue to flow through eventNotifier
// Cancel when done:
await pool.unsubscribe(req);
```

### Background Queries

Start queries without waiting for results:

```dart
// Fire and forget - events saved to DB when they arrive
await pool.query(
  RequestFilter(kinds: {1}).toRequest(),
  source: RemoteSource(background: true),
);
// Returns immediately, events processed in background
```

## Relay Status Types

### PoolStatus
Complete status of the WebSocket pool:

```dart
class PoolStatus {
  final Map<String, RelayConnectionInfo> connections;
  final Map<String, SubscriptionInfo> subscriptions;
  final Map<String, PublishInfo> publishes;
  final List<ErrorEntry> recentErrors; // Last 100 errors
  final DateTime lastUpdated;
}
```

### RelayConnectionInfo
Status of individual relay connections (simplified):

```dart
class RelayConnectionInfo {
  final String url;
  final RelayConnectionState state; // disconnected, connecting, connected, reconnected
  final DateTime? lastActivity;
  final int reconnectAttempts;
  final DateTime lastStatusChange; // When state last changed
}
```

**Relay States (Simple):**
- `disconnected` - Relay is offline
- `connecting` - Initial connection in progress
- `connected` - Relay is connected (first time)
- `reconnected` - Relay reconnected after initial connection

### SubscriptionInfo
Active subscription tracking (simplified - no status, relays tell the story):

```dart
class SubscriptionInfo {
  final String subscriptionId;
  final Set<String> targetRelays;        // Relays we want to query
  final Set<String> connectedRelays;     // Relays where request is CURRENTLY ACTIVE
  final Set<String> eoseReceived;        // Relays that sent EOSE
  final SubscriptionPhase phase;         // eose or streaming
  final DateTime startTime;
  final Map<String, dynamic>? requestFilters;
  
  // Reconnection tracking
  final Map<String, int> reconnectionCount;      // Reconnections per relay
  final Map<String, DateTime> lastReconnectTime; // Last reconnect timestamp per relay
  final Set<String> resyncing;                   // Relays currently re-syncing
}
```

**How to Determine if a Subscription is Active:**
- A subscription is active on a relay if the relay URL is in `connectedRelays`
- Check relay state from `PoolStatus.connections[relayUrl].state`
- If relay is `disconnected`, it cannot be in `connectedRelays` (automatically removed)
- If relay is `connected` or `reconnected` AND in `connectedRelays` → Request is active

### ErrorEntry
Error tracking with context:

```dart
class ErrorEntry {
  final DateTime timestamp;
  final String message;
  final String? relayUrl;
  final String? subscriptionId;
  final String? eventId;
}
```

## Configuration Options

```dart
StorageConfiguration(
  // Database
  databasePath: 'myapp.db', // null for in-memory
  
  // Relay groups
  relayGroups: {
    'default': {'wss://relay1.com', 'wss://relay2.com'},
    'backup': {'wss://relay3.com'},
  },
  defaultRelayGroup: 'default',
  
  // Timeouts
  responseTimeout: Duration(seconds: 10),     // Max wait for relay response
  streamingBufferWindow: Duration(milliseconds: 100), // Event batching
  idleTimeout: Duration(seconds: 30),         // Disconnect idle relays
  
  // Verification
  skipVerification: false, // Set true to skip signature verification
  
  // Query defaults
  defaultQuerySource: LocalSource(), // or RemoteSource()
)
```

## Testing

Run the test suite:

```bash
dart test
```

All 99 tests cover:
- Local storage operations (save, query, clear)
- Remote operations (publish, query, cancel)
- WebSocket pool management (connections, reconnection)
- Request optimization
- Event deduplication
- Error handling
- Performance and stress testing

## Architecture Notes

### Isolate-Based Design
Purplebase runs all database and network operations in a background isolate to keep your UI responsive. Communication happens via message passing.

### Two-Notifier Pattern
- **RelayEventNotifier**: Data channel (message bus pattern)
  - Emits batched events as they arrive
  - Ephemeral state (process immediately)
- **PoolStatusNotifier**: Meta channel (queryable state)
  - Throttled status updates
  - Queryable at any time
  - Circular error buffer (last 100)

### WebSocket Pool as Service
The pool is a plain service class (not a StateNotifier) that coordinates:
- Connection lifecycle management
- Automatic reconnection with exponential backoff
- Request multiplexing across relays
- EOSE (End of Stored Events) detection
- Event deduplication
- Timestamp-based optimization

## Contributing

Contributions welcome! Please read [ARCHITECTURE.md](ARCHITECTURE.md) for design details.

## License

MIT