/// WebSocket pool - re-exports for backwards compatibility
library;

import 'pool.dart' as pool;

export 'connection.dart' show PublishResult;
export 'pool.dart' show RelayPool, PublishRelayResponse;
export 'state.dart';
export 'subscription.dart' show Subscription;

// Legacy alias for backwards compatibility
typedef WebSocketPool = pool.RelayPool;
