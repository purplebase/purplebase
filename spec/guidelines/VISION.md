---
description: Product vision — what purplebase is, who it serves, what success means
alwaysApply: true
---

# purplebase — Vision

## What purplebase Is

The concrete storage backend for the `models` library: a SQLite database + background-isolate relay pool that implements `StorageNotifier`, giving Flutter/Dart apps a persistent, connectivity-aware, local-first Nostr data layer.

## Who Uses It

- **Flutter app developers** who use `models` and need a production-ready `StorageNotifier` backed by SQLite and real WebSocket relay connections.
- **zapstore and similar apps** that need multi-relay querying, outbox-ready relay resolution, and offline-first behavior without managing relay connections themselves.

## What Success Means

- Apps initialize with a single `PurplebaseStorageNotifier` and get persistent storage, relay connectivity, and reactive queries with no additional setup.
- Relay queries always resolve within a bounded time (EOSE + grace window, or absolute timeout) — the app never hangs waiting for a relay.
- The SQLite database is the single source of truth; relay data is always written to local storage before being surfaced to the app.
- The relay pool runs in a background isolate — relay I/O never blocks the UI thread.
- Connectivity changes (offline/online) are handled gracefully: queries pause and resume automatically.

## Non-Goals

- **No model type definitions** — all Nostr kinds, `Model`/`PartialModel` classes, and the `StorageNotifier` contract live in `models`.
- **No UI layer** — purplebase is a pure data/network package with no widgets.
- **No server-side / web** — targets mobile and desktop Dart only (SQLite + Dart isolates).
- **No cryptographic signing** — signing is handled by signer packages (`amber_signer`, `nip46_signer`, etc.) that implement the `Signer` interface from `models`.
