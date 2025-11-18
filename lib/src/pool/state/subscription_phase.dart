/// Phase of subscription lifecycle
enum SubscriptionPhase {
  /// Waiting for EOSE from relays
  eose,

  /// EOSE received, now streaming new events
  streaming,
}

/// How is a subscription doing on a specific relay?
sealed class RelaySubscriptionPhase {
  const RelaySubscriptionPhase();
}

/// Subscription request sent to relay, awaiting response
class SubscriptionPending extends RelaySubscriptionPhase {
  const SubscriptionPending();

  @override
  String toString() => 'Pending';
}

/// Subscription is active and receiving events
class SubscriptionActive extends RelaySubscriptionPhase {
  const SubscriptionActive();

  @override
  String toString() => 'Active';
}

/// Subscription is re-syncing after reconnection
class SubscriptionResyncing extends RelaySubscriptionPhase {
  const SubscriptionResyncing();

  @override
  String toString() => 'Resyncing';
}

/// Subscription failed on this relay
class SubscriptionFailed extends RelaySubscriptionPhase {
  final String reason;

  const SubscriptionFailed(this.reason);

  @override
  String toString() => 'Failed($reason)';
}





