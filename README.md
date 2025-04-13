# purplebase

A powerful local-first nostr client framework written in Dart.

Reference implementation of [models](https://github.com/purplebase/models).

## TODO

 - [ ] Cancel subs on disposing request notifier
 - [ ] Latest req timestamp in database and use for subsequent requests (pool)
 - [ ] Reconnect and rerequest unclosed subscriptions, use latest timestamp (pool)
 - [ ] Publish to relays
 - [ ] Outbox model