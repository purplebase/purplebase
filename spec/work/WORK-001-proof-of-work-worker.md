# WORK-001 — Proof-of-Work Worker

**Feature:** FEAT-001-proof-of-work-worker.md
**Status:** Complete

## Tasks

- [x] 1. Add an isolated NIP-13 executor
- [x] 2. Add explicit operation cancellation and cleanup
- [x] 3. Export the executor from purplebase
- [x] 4. Cover success, failure, cancellation, and concurrency
- [x] 5. Run analysis and tests
- [x] 6. Self-review against INVARIANTS.md

## Test Coverage

| Scenario | Expected | Status |
|----------|----------|--------|
| Successful mining | Valid result returned off-isolate | [x] |
| Cancellation | Worker stops and future completes with cancellation | [x] |
| Mining limit | Typed models error propagates | [x] |
| Concurrent operations | Results and cancellation stay isolated | [x] |

## Decisions

### 2026-07-13 — Dedicated short-lived worker

**Context:** PoW is CPU-bound and unrelated to relay-pool state.
**Decision:** Spawn one short-lived isolate per mining operation.
**Rationale:** Cancellation is an immediate isolate kill, secrets are not
involved, and relay-pool/SQLite ownership remains unchanged.

## Spec Issues

_None_

## Progress Notes

**2026-07-13:** Work started for Zapstore's device-private event contract.

**2026-07-13:** Worker implementation, cancellation cleanup, analysis, and
serial full test suite completed successfully.
