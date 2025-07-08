# Purplebase Architecture

Purplebase is a high-performance, local-first Nostr client library for Dart that provides a concrete implementation of the [Models](../models) framework. It offers SQLite-based local storage, optimized WebSocket relay communication, and advanced performance features like caching, throttling, and background processing.

## Overview

Purplebase extends the Models framework by providing:
- **PurplebaseStorageNotifier**: A SQLite-based storage implementation
- **WebSocketPool**: Optimized relay communication with connection pooling
- **Isolate Architecture**: Background processing to keep the UI responsive
- **Performance Optimizations**: Caching, throttling, and request optimization

```mermaid
graph TB
    subgraph "Application Layer"
        App[Flutter/Dart App]
        UI[UI Components]
    end
    
    subgraph "Models Framework"
        Domain[Domain Models<br/>Note, Profile, Reaction]
        Query[Query System<br/>query&lt;T&gt;]
        Storage[StorageNotifier<br/>Abstract Interface]
    end
    
    subgraph "Purplebase Implementation"
        PurpleStorage[PurplebaseStorageNotifier<br/>SQLite Implementation]
        Isolate[Background Isolate<br/>Heavy Operations]
        WebSocketPool[WebSocketPool<br/>Relay Communication]
        DB[(SQLite Database<br/>Local Storage)]
    end
    
    subgraph "External Systems"
        Relays[Nostr Relays<br/>WebSocket Connections]
    end
    
    App --> UI
    UI --> Query
    Query --> Storage
    Storage --> PurpleStorage
    PurpleStorage --> Isolate
    Isolate --> WebSocketPool
    Isolate --> DB
    WebSocketPool --> Relays
    
    classDef models fill:#e1f5fe
    classDef purplebase fill:#f3e5f5
    classDef external fill:#fff3e0
    
    class Domain,Query,Storage models
    class PurpleStorage,Isolate,WebSocketPool,DB purplebase
    class App,UI,Relays external
```

## Core Components

### 1. Storage Layer Architecture

Purplebase implements the Models `StorageNotifier` interface with SQLite backend and isolate-based processing:

```mermaid
graph TB
    subgraph "Main Isolate"
        App[Application]
        PurpleStorage[PurplebaseStorageNotifier]
        SendPort[Send Port]
    end
    
    subgraph "Background Isolate"
        IsolateEntry[isolateEntryPoint]
        Operations[Operation Handlers]
        WSPool[WebSocketPool]
        SQLite[(SQLite Database)]
    end
    
    subgraph "Operations"
        LocalQuery[LocalQueryIsolateOperation]
        LocalSave[LocalSaveIsolateOperation]
        RemoteQuery[RemoteQueryIsolateOperation]
        RemotePublish[RemotePublishIsolateOperation]
        RemoteCancel[RemoteCancelIsolateOperation]
    end
    
    App --> PurpleStorage
    PurpleStorage --> SendPort
    SendPort -.-> IsolateEntry
    IsolateEntry --> Operations
    Operations --> LocalQuery
    Operations --> LocalSave
    Operations --> RemoteQuery
    Operations --> RemotePublish
    Operations --> RemoteCancel
    
    LocalQuery --> SQLite
    LocalSave --> SQLite
    RemoteQuery --> WSPool
    RemotePublish --> WSPool
    RemoteCancel --> WSPool
```

### 2. WebSocket Pool

The WebSocket pool manages connections to Nostr relays with advanced optimization features:

```mermaid
graph TB
    subgraph "WebSocketPool"
        Pool[WebSocketPool<br/>StateNotifier]
        RelayStates[Relay States<br/>Connection Management]
        Subscriptions[Subscription States<br/>Request Tracking]
        PublishStates[Publish States<br/>Event Publishing]
    end
    
    subgraph "Performance Features"
        LRUCache[LRU Timestamp Cache<br/>1000 entries max]
        EventBuffer[Event Buffering<br/>Throttled flushing]
        Deduplication[Event Deduplication<br/>Per subscription]
        Optimization[Request Optimization<br/>Automatic since filters]
    end
    
    subgraph "Relay Management"
        IdleTimer[Idle Connection Cleanup]
        Reconnection[Automatic Reconnection]
        LoadBalancing[Multi-Relay Support]
    end
    
    Pool --> RelayStates
    Pool --> Subscriptions
    Pool --> PublishStates
    Pool --> LRUCache
    Pool --> EventBuffer
    Pool --> Deduplication
    Pool --> Optimization
    Pool --> IdleTimer
    Pool --> Reconnection
    Pool --> LoadBalancing
```

### 3. Database Schema

SQLite database optimized for Nostr event storage with compression and indexing:

```mermaid
erDiagram
    events {
        TEXT id PK
        TEXT pubkey
        INTEGER kind
        DATETIME created_at
        BLOB blob
    }
    
    event_tags {
        TEXT event_id PK
        TEXT value PK
        INTEGER is_relay
    }
    
    events ||--o{ event_tags : "has tags"
```

**Schema Notes:**
- **events table**: Primary key is event ID, indexed on pubkey/kind/created_at, blob contains compressed content/tags/signature
- **event_tags table**: Composite primary key (event_id + value), indexed on value, is_relay: 0=tag, 1=relay_url

## Data Flow Patterns

### 1. Query Flow

```mermaid
sequenceDiagram
    participant App
    participant Storage
    participant Isolate
    participant SQLite
    participant WSPool
    participant Relay
    
    App->>Storage: query<Note>(filters)
    Storage->>Isolate: LocalQueryIsolateOperation
    Isolate->>SQLite: SQL query with params
    SQLite-->>Isolate: Local results
    Isolate-->>Storage: Results + start remote
    Storage-->>App: Local data immediately
    
    par Background Remote Query
        Isolate->>WSPool: RemoteQueryIsolateOperation
        WSPool->>Relay: REQ with optimized filters
        Relay-->>WSPool: EVENT messages
        WSPool->>SQLite: Save new events
        SQLite-->>Isolate: Updated IDs
        Isolate-->>Storage: QueryResultMessage
        Storage-->>App: Reactive update
    end
```

### 2. Event Publishing Flow

```mermaid
sequenceDiagram
    participant App
    participant Storage
    participant Isolate
    participant WSPool
    participant Relay
    
    App->>Storage: publish(events)
    Storage->>Isolate: RemotePublishIsolateOperation
    Isolate->>WSPool: publish(events, relayUrls)
    
    par Multi-Relay Publishing
        WSPool->>Relay: EVENT message
        Relay-->>WSPool: OK/NOTICE response
    end
    
    WSPool-->>Isolate: PublishResponse
    Isolate-->>Storage: Success/failure
    Storage-->>App: PublishResponse
```

### 3. Real-time Updates

```mermaid
sequenceDiagram
    participant UI
    participant Riverpod
    participant Storage
    participant Isolate
    participant WSPool
    participant Relay
    
    UI->>Riverpod: ref.watch(query<Note>())
    Riverpod->>Storage: Subscribe to changes
    
    loop Real-time Events
        Relay->>WSPool: EVENT message
        WSPool->>WSPool: Buffer & deduplicate
        WSPool->>Isolate: Save to SQLite
        Isolate->>Storage: QueryResultMessage
        Storage->>Riverpod: State update
        Riverpod->>UI: Rebuild with new data
    end
```

## Performance Optimizations

### 1. Request Optimization

```mermaid
graph TB
    subgraph "Request Optimization Pipeline"
        Original[Original Request]
        Canonical[Canonical Request<br/>Remove since/until]
        Hash[SHA256 Hash<br/>relay + canonical]
        Lookup[LRU Cache Lookup]
        Optimize[Add since filter<br/>from latest event]
        Send[Send optimized REQ]
    end
    
    Original --> Canonical
    Canonical --> Hash
    Hash --> Lookup
    Lookup --> Optimize
    Optimize --> Send
    
    subgraph "Cache Management"
        LRU[LRU Cache<br/>1000 entries]
        Eviction[Automatic Eviction<br/>Oldest entries]
        Timestamp[Event Timestamp<br/>Storage]
    end
    
    Lookup --> LRU
    LRU --> Eviction
    Send --> Timestamp
    Timestamp --> LRU
```

### 2. Event Buffering & Throttling

```mermaid
graph TB
    subgraph "Event Processing"
        Receive[Receive EVENT]
        Dedupe[Deduplication Check]
        Buffer[Add to Buffer]
        Schedule[Schedule Flush]
        Flush[Flush Buffer]
        Emit[Emit State Update]
    end
    
    subgraph "Buffer Management"
        EoseBuffer[EOSE Buffer<br/>Until end-of-stored]
        StreamBuffer[Streaming Buffer<br/>Throttled window]
        Timer[Flush Timer<br/>Configurable delay]
    end
    
    Receive --> Dedupe
    Dedupe --> Buffer
    Buffer --> EoseBuffer
    Buffer --> StreamBuffer
    Buffer --> Schedule
    Schedule --> Timer
    Timer --> Flush
    Flush --> Emit
```

### 3. Database Optimizations

```mermaid
graph TB
    subgraph "SQLite Configuration"
        WAL[WAL Mode<br/>Better concurrency]
        MMap[Memory Mapping<br/>512MB mmap_size]
        Cache[Page Cache<br/>20MB cache_size]
        Compression[ZLib Compression<br/>Content + tags]
    end
    
    subgraph "Query Optimization"
        Prepared[Prepared Statements<br/>Parameter binding]
        Indexes[Optimized Indexes<br/>pubkey, kind, created_at]
        Batch[Batch Operations<br/>Transaction grouping]
    end
    
    subgraph "Storage Strategy"
        Dedup[Event Deduplication<br/>ON CONFLICT handling]
        Replaceable[Replaceable Events<br/>Automatic replacement]
        Verification[Optional Verification<br/>Configurable]
    end
    
    WAL --> Prepared
    MMap --> Indexes
    Cache --> Batch
    Compression --> Dedup
    Prepared --> Replaceable
    Indexes --> Verification
```

## Configuration & Customization

### 1. Storage Configuration

```dart
final config = StorageConfiguration(
  databasePath: 'nostr.db',
  skipVerification: false,
  keepSignatures: true,
  
  // Relay configuration
  relayGroups: {
    'primary': {'wss://relay1.com', 'wss://relay2.com'},
    'backup': {'wss://relay3.com'},
  },
  defaultRelayGroup: 'primary',
  
  // Performance tuning
  responseTimeout: Duration(seconds: 10),
  streamingBufferWindow: Duration(milliseconds: 300),
  idleTimeout: Duration(minutes: 5),
);
```

### 2. Relay Groups

```mermaid
graph TB
    subgraph "Relay Groups"
        Primary[Primary Group<br/>Fast, reliable relays]
        Backup[Backup Group<br/>Fallback relays]
        Specialized[Specialized Group<br/>Topic-specific relays]
    end
    
    subgraph "Source Selection"
        LocalOnly[LocalSource<br/>Database only]
        RemoteOnly[RemoteSource<br/>Relays only]
        Hybrid[LocalAndRemoteSource<br/>Best of both]
    end
    
    Primary --> RemoteOnly
    Backup --> RemoteOnly
    Specialized --> RemoteOnly
    LocalOnly --> Database[(Local Database)]
    Hybrid --> Database
    Hybrid --> Primary
```

## Testing & Development

### 1. Testing Architecture

```mermaid
graph TB
    subgraph "Test Environment"
        TestRunner[Test Runner]
        TestRelay[Test Relay Server]
        InMemoryDB[In-Memory SQLite]
        TestSigner[Test Signer]
    end
    
    subgraph "Test Categories"
        Unit[Unit Tests<br/>Individual components]
        Integration[Integration Tests<br/>Full data flow]
        Performance[Performance Tests<br/>Load & stress]
        Remote[Remote Tests<br/>Real relay integration]
    end
    
    TestRunner --> Unit
    TestRunner --> Integration
    TestRunner --> Performance
    TestRunner --> Remote
    
    Unit --> InMemoryDB
    Integration --> TestRelay
    Performance --> TestSigner
    Remote --> TestRelay
```

### 2. Development Features

- **Hot Reload**: Preserves database state during development
- **Logging**: Comprehensive debug information via InfoNotifier
- **Metrics**: Performance monitoring and optimization insights
- **Debugging**: Isolate-safe debugging with proper error handling

## Best Practices

### 1. Query Optimization

```dart
// ✅ Good: Specific filters reduce relay load
final notes = await storage.query<Note>(
  authors: {specificPubkey},
  kinds: {1}, // Text notes only
  since: DateTime.now().subtract(Duration(hours: 24)),
  limit: 50,
);

// ❌ Bad: Broad queries are expensive
final allNotes = await storage.query<Note>();
```

### 2. Background Processing

```dart
// ✅ Good: Use background source for non-critical updates
final backgroundNotes = query<Note>(
  authors: {pubkey},
  source: RemoteSource(background: true),
);

// ✅ Good: Combine local and remote for immediate + fresh data
final hybridNotes = query<Note>(
  authors: {pubkey},
  source: LocalAndRemoteSource(),
);
```

### 3. Memory Management

```dart
// ✅ Good: Use streaming for large datasets
final stream = query<Note>(
  kinds: {1},
  limit: 1000,
  source: RemoteSource(stream: true),
);

// ✅ Good: Cancel subscriptions when done
await storage.cancel(request);
```

## Performance Characteristics

- **Local Queries**: < 10ms typical response time
- **Remote Queries**: 100-500ms initial response, then streaming
- **Event Processing**: 10,000+ events/second throughput
- **Memory Usage**: ~50MB for 100k events (with compression)
- **Database Size**: ~20MB for 100k events (compressed)

## Monitoring & Debugging

### 1. Info System

```dart
// Listen to debug information
ref.listen(infoNotifierProvider, (_, message) {
  if (message != null) {
    print('Purplebase: ${message.message}');
  }
});
```

### 2. Performance Metrics

The system provides built-in performance monitoring:
- Connection status and latency
- Query execution times
- Cache hit rates
- Event processing throughput
- Database statistics

---

This architecture provides a robust, scalable foundation for building high-performance Nostr applications while maintaining the simplicity and reactivity of the Models framework. 