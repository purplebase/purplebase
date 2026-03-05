---
description: Quality expectations — when to spec, testing, anti-patterns, AI workflow
alwaysApply: true
---

# purplebase — Quality Bar

## When to Create a Feature Spec

Create a spec if the work:

- Touches the isolate message protocol (`messages.dart`) or the isolate entry point
- Changes the EOSE + grace window algorithm or any timeout constant in `PoolConstants`
- Modifies the SQLite schema (`schema.dart`) — including adding columns, indexes, or migrations
- Changes `QueryBuilder` in a way that could affect query correctness or performance
- Alters relay reconnect logic, backoff strategy, or zombie detection
- Adds or removes a field on `PoolConfiguration`, `StorageConfiguration`, or `PoolState`
- Changes how relay resolution works (label → URL mapping)
- Could regress the "always resolves" guarantee

**Skip the spec** if:

- Adjusting a log message or adding a `LogLevel.info` entry
- Pure cosmetic changes (rename, formatting, doc comment)
- Bug fix with an obvious, isolated cause
- Dependency update with no API changes

When in doubt, create a spec. The overhead is low.

## Testing

- Integration tests use `test-relay` (the local relay in this monorepo) — no external relay calls.
- Unit tests for `QueryBuilder`, `RequestTracker`, `EventBuffer`, and `codec` use plain Dart with no isolates or sockets.
- Tests must not rely on timing (no `sleep`, no `Future.delayed` for correctness). Use completers and explicit flush triggers instead.
- Test both the happy path and failure paths for relay connections: connect, EOSE, timeout, disconnect, reconnect, max-retries-exceeded.
- Test that `obliterate()` leaves the storage in a state where re-initialization succeeds.
- Test that publishing to a relay that rejects the event returns a `PublishResponse` with `accepted: false` — not a thrown exception.

## Implementation Expectations

- Follow the existing pattern in the nearest module before inventing a new approach.
- New relay protocol messages go in `messages.dart` with a corresponding handler in `isolate_entry.dart`.
- New SQL queries go through `QueryBuilder` — raw SQL strings scattered through `purplebase_storage.dart` are an anti-pattern.
- `PurplebaseStorageNotifier` orchestrates; it must not contain business logic that belongs in `RelayPool`, `QueryBuilder`, or `codec`.
- Code must be structured for human review first, not for AI generation convenience.

## Anti-Patterns

- **Direct SQLite access from the background isolate** — the pool produces raw maps; the main isolate owns the DB.
- **Blocking the main isolate on relay I/O** — all relay operations go through the isolate bridge.
- **Hardcoded relay URLs** — relay targets are always resolved through `StorageNotifier.resolveRelays`; never hardcoded in pool or storage code.
- **Disabling timeouts** — setting `eoseTimeout` or `responseTimeout` to `Duration.zero` in production code is forbidden.
- **Swallowing isolate errors** — errors from the background isolate must surface as `StorageError` states, not be silently dropped.
- **Unbounded log growth** — `_logs` in `RelayPool` is capped at `PoolConstants.maxLogEntries`; never append without trimming.
- **Ignoring `_disposed` flag** — every async callback in `RelayPool` must check `_disposed` before acting.

## Working With AI

- Spec-first for any change to the isolate protocol, EOSE algorithm, or SQLite schema.
- Work packets in `spec/work/` for non-trivial tasks.
- If a spec is unclear or incorrect, stop and report a Spec Issue — do not guess.
- Never modify `spec/guidelines/` without explicit permission.

## Knowledge Entries

After a work packet merges, promote non-obvious decisions to `spec/knowledge/DEC-XXX-*.md`. See `spec/knowledge/_TEMPLATE.md` for format and criteria.

### Task Completeness

For non-trivial work, changes are not complete unless:

- Work packet reflects the actual work performed
- No significant code exists outside the task plan
- Edge cases and failure modes are addressed (relay failures, timeouts, offline transitions)
