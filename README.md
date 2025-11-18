# purplebase

A powerful local-first nostr client framework written in Dart with built-in WebSocket pool management and background isolate support.

Reference implementation of [models](https://github.com/purplebase/models).

## Features

- 🔄 **Local-First Architecture** - SQLite-backed storage with background isolate processing
- 🌐 **Smart WebSocket Pool** - Self-managing relay agents with automatic reconnection
- 📊 **Dual-Channel Notifications** - Separate data and status channels for clean state management
- 🎯 **Event Deduplication** - Intelligent handling of events from multiple relays
- 🔍 **Queryable Status** - Real-time visibility into connections, subscriptions, and errors
- ⚙️ **Configurable Batching** - Low-latency streaming with tunable flush windows
- 💪 **Battle-tested** - 116+ passing tests covering all scenarios

## Architecture in 30 seconds

- Background isolate handles SQLite + WebSocket pool so the UI thread stays smooth.
- Two notifiers:
  - `RelayEventNotifier` (data channel): batches events & notices.
  - `poolStateProvider` (meta channel): connections, subscriptions, health.
- Self-managing relay agents (one per relay) with exponential backoff + an explicit `ensureConnected()` hook so the UI can force immediate reconnection after waking or regaining connectivity.
- Full internals live in [ARCHITECTURE.md](ARCHITECTURE.md).

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
  responseTimeout: Duration(seconds: 15),
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

### Handling App Lifecycle (Recommended)

When your app resumes (or connectivity changes), call `ensureConnected()` to immediately reconnect relays instead of waiting for the normal backoff window:

```dart
// Flutter example
class MyApp extends StatefulWidget {
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Force immediate health check after wake
      ref.read(storageNotifierProvider.notifier).ensureConnected();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(/* ... */);
  }
}
```

This bypasses any pending backoff delay, so relays come back online as soon as the OS lets sockets through again.

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

### Monitoring Pool State

Access everything through the single `poolStateProvider`:

```dart
// In your UI widget
final poolState = ref.watch(poolStateProvider);

// Check which relays have sent EOSE for a subscription
final withEose = poolState.getRelaysWithEose(subscriptionId);
final waitingForEose = poolState.getRelaysWaitingForEose(subscriptionId);

// Check EOSE status per relay
final subscription = poolState.subscriptions[subscriptionId];
if (subscription != null) {
  for (final url in subscription.targetRelays) {
    final status = subscription.relayStatus[url];
    if (status?.eoseReceivedAt != null) {
      print('$url: EOSE received at ${status!.eoseReceivedAt}');
    } else {
      print('$url: Still waiting for EOSE');
    }
  }
}

// Access connection and subscription state
Widget build(BuildContext context, WidgetRef ref) {
  final poolState = ref.watch(poolStateProvider);
  
  if (poolState == null) return CircularProgressIndicator();
  
  return Column(
    children: [
      // Check specific relay connection
      if (poolState.connections['wss://relay.damus.io']?.isConnected ?? false)
        Text('Damus: Connected ✅')
      else
        Text('Damus: Offline ❌'),
        
      // Show relay connection phase
      Text('Phase: ${poolState.connections['wss://relay.damus.io']?.phase}'),
      
      // Show when phase started
      Text('Since: ${poolState.connections['wss://relay.damus.io']?.phaseStartedAt}'),
      
      // Check subscription status
      ...poolState.subscriptions.entries.map((entry) {
        final subId = entry.key;
        final sub = entry.value;
        
        return ListTile(
          title: Text(subId),
          subtitle: Text('${sub.relayStatus.length} relays - Phase: ${sub.phase}'),
          trailing: Text('${sub.totalEventsReceived} events'),
        );
      }),
      
      // Show health metrics
      Text('Total Connections: ${poolState.health.totalConnections}'),
      Text('Connected: ${poolState.health.connectedCount}'),
      Text('Total Subs: ${poolState.health.totalSubscriptions}'),
      Text('Fully Active: ${poolState.health.fullyActiveSubscriptions}'),
    ],
  );
}
```

**Available Data in `PoolState`:**
- `connections` - Map of relay URL to `RelayConnectionState` (phase, reconnect attempts, last message time)
- `subscriptions` - Map of subscription ID to `SubscriptionState` (relay statuses, phase, event count, EOSE status per relay)
- `publishes` - Map of publish ID to `PublishOperation` (per-relay responses)
- `health` - `HealthMetrics` with counters and statistics
- `timestamp` - When this state snapshot was created

**Convenience Methods:**
- `getRelaysWithEose(subscriptionId)` - Returns Set of relays that have sent EOSE
- `getRelaysWaitingForEose(subscriptionId)` - Returns Set of relays still waiting for EOSE
- `isRelayConnected(relayUrl)` - Returns true if relay is connected
- `isSubscriptionFullyActive(subscriptionId)` - Returns true if all target relays are connected and active
- `getActiveRelayCount(subscriptionId)` - Returns number of connected relays for subscription
- `subscriptionDetails(subscriptionId)` - Returns detailed debug string showing EOSE status per relay

**Example: Display EOSE Status in UI**

```dart
Widget buildSubscriptionStatus(String subscriptionId, PoolState poolState) {
  final subscription = poolState.subscriptions[subscriptionId];
  if (subscription == null) return Text('No subscription found');
  
  final withEose = poolState.getRelaysWithEose(subscriptionId);
  final waitingForEose = poolState.getRelaysWaitingForEose(subscriptionId);
  
  return Card(
    child: Column(
      children: [
        ListTile(
          title: Text('Subscription ${subscriptionId.substring(0, 8)}...'),
          subtitle: Text('Phase: ${subscription.phase}'),
          trailing: Text('${subscription.totalEventsReceived} events'),
        ),
        
        // EOSE Progress
        Padding(
          padding: EdgeInsets.all(8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('EOSE Status: ${withEose.length}/${subscription.targetRelays.length} relays'),
              SizedBox(height: 8),
              
              // Show per-relay status
              ...subscription.targetRelays.map((url) {
                final status = subscription.relayStatus[url];
                final connection = poolState.connections[url];
                final hasEose = status?.eoseReceivedAt != null;
                final isConnected = connection?.phase is Connected;
                
                return Padding(
                  padding: EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        isConnected ? Icons.wifi : Icons.wifi_off,
                        size: 16,
                        color: isConnected ? Colors.green : Colors.red,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          url.replaceFirst('wss://', ''),
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      Icon(
                        hasEose ? Icons.check_circle : Icons.hourglass_empty,
                        size: 16,
                        color: hasEose ? Colors.green : Colors.orange,
                      ),
                      SizedBox(width: 4),
                      Text(
                        hasEose ? 'EOSE ✓' : 'Waiting...',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    ),
  );
}
```

### Relay Disconnection & Reconnection

The pool uses self-managing relay agents to handle connection lifecycles:

#### **Connection Phases:**
- `Connecting` – Connection attempt in progress
- `Connected` – Successfully connected and ready
- `Disconnected` – Connection lost (reason + reconnect metadata)

#### **Disconnection Flow:**
1. Relay phase → `Disconnected(reason)`
2. Pool detects disconnection via WebSocket state change
3. Active subscriptions marked as needing resync
4. Exponential backoff calculates next retry window

#### **Reconnection Flow:**
1. Scheduler or `ensureConnected()` triggers a retry
2. Connection attempt with timeout
3. On success → `Connected` (with `isReconnection: true`)
4. All active subscriptions **automatically re-sent**
5. Events continue flowing

#### **UI Example:**

```dart
Widget build(BuildContext context, WidgetRef ref) {
  final poolState = ref.watch(poolStateProvider);
  
  if (poolState == null) return SizedBox();
  
  return ListView(
    children: poolState.subscriptions.values.map((sub) {
      // Count how many relays are in good state
      final activeCount = sub.relayStatuses.values
          .where((s) => s.phase is SubscriptionActive)
          .length;
      final totalCount = sub.relayStatuses.length;
      
      Color indicatorColor;
      String statusText;
      
      if (activeCount == totalCount) {
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
        subtitle: Text('$statusText - ${sub.eventCount} events'),
        trailing: Text(sub.phase.name),
      );
    }).toList(),
  );
}
```

#### **Key Highlights**
- Self-managing relay agents with explicit `Connecting / Connected / Disconnected` phases
- Exponential backoff plus `ensureConnected()` fast-path
- Cross-relay deduplication & batching via `SubscriptionBuffer`
- Pool state + health metrics exposed through one provider

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

## Pool State Types

### PoolState
Complete state snapshot of the WebSocket pool:

```dart
class PoolState {
  final Map<String, RelayConnectionState> connections;
  final Map<String, SubscriptionState> subscriptions;
  final Map<String, PublishOperation> publishes;
  final HealthMetrics health;
  final DateTime timestamp;
}
```

### RelayConnectionState
State of individual relay connections:

```dart
class RelayConnectionState {
  final String url;
  final ConnectionPhase phase; // Connecting, Connected, Disconnected
  final DateTime phaseStartedAt;
  final int reconnectAttempts;
  final DateTime? lastMessageAt;
  final String? lastError;
}
```

**Connection Phases (Sealed Classes):**
- `Connecting` - Connection attempt in progress  
- `Connected` - Successfully connected (tracks if this is a reconnection)
- `Disconnected` - Connection lost (includes reason, attempts, next retry)

### SubscriptionState
Active subscription tracking with per-relay status:

```dart
class SubscriptionState {
  final String subscriptionId;
  final SubscriptionPhase phase; // eose or streaming
  final Map<String, RelaySubscriptionStatus> relayStatuses; // Per-relay state
  final int eventCount;
  final DateTime createdAt;
}
```

**Subscription Phases:**
- `eose` - Waiting for End of Stored Events from all relays
- `streaming` - Actively receiving new events

**Per-Relay Subscription Status (Sealed Classes):**
- `SubscriptionPending` - Waiting for subscription to be sent
- `SubscriptionActive` - Subscription active, receiving events
- `SubscriptionResyncing` - Relay reconnected, re-sending subscription
- `SubscriptionFailed` - Subscription failed (includes error message)

### HealthMetrics
Health and performance metrics:

```dart
class HealthMetrics {
  final int totalEventsReceived;
  final int totalEventsDeduplicated;
  final int totalPublishes;
  final int activeConnections;
  final int activeSubscriptions;
  final int totalErrors;
  final DateTime lastHealthCheck;
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
  responseTimeout: Duration(seconds: 15),     // Max wait for relay response
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

68+ tests cover:
- Local storage operations (save, query, clear)
- Remote operations (publish, query, cancel)
- WebSocket pool management (connections, reconnection)
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
- **PoolStateNotifier**: Meta channel (queryable state)
  - Throttled state updates
  - Queryable at any time
  - Health metrics and connection/subscription status

### WebSocket Pool Architecture
The pool uses self-managing relay agents:
- **RelayAgent**: Each relay connection is independent and self-managing
  - Explicit connection phases (sealed classes)
  - Automatic reconnection with exponential backoff
  - Detects disconnections via socket lifecycle events
- **Event Buffering**: Batching and deduplication via SubscriptionBuffer
- **Per-Relay Tracking**: Independent state per relay-subscription pair
- **Automatic Resync**: Re-sends subscriptions after reconnection

## Contributing

Contributions welcome! Please read [ARCHITECTURE.md](ARCHITECTURE.md) for design details.

## License

MIT