/// WebSocket pool - re-exports for backwards compatibility
library;

import 'pool.dart' as pool;

export 'pool.dart' show RelayPool, PublishRelayResponse;
export 'state.dart';

// Legacy alias for backwards compatibility
typedef WebSocketPool = pool.RelayPool;
