# FEAT-001 — Proof-of-Work Worker

## Goal

Provide a cancellable NIP-13 executor that mines finalized event fields in a
background isolate so application UI isolates never run the hash loop.

## Non-Goals

- Selecting event kinds or target difficulty
- Signing, encryption, storage, or relay publication
- Sharing the relay-pool isolate

## User-Visible Behavior

- Mining does not stall UI rendering.
- Cancellation and worker failures resolve explicitly.
- Worker resources are released after every operation.

## Edge Cases

- Cancellation before worker startup completes
- Attempt or timeout exhaustion
- Worker error or unexpected exit
- Concurrent independent mining operations

## Acceptance Criteria

- [ ] Mining runs in a spawned worker isolate.
- [ ] The caller can cancel an in-flight operation.
- [ ] Cancellation terminates the worker and completes the future once.
- [ ] Success returns the nonce, ID, difficulty, attempts, and elapsed time.
- [ ] No relay-pool or SQLite ownership rule is changed.
