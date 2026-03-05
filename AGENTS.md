# purplebase — Agent Instructions

A fast, local-first Nostr client library in Dart providing relay management, storage, and event handling.

All behavioral authority lives in `spec/guidelines/`. If this file conflicts, guidelines win.

## Quick Reference

| What | Where |
|------|-------|
| Architecture & patterns | `spec/guidelines/ARCHITECTURE.md` |
| Non-negotiable rules | `spec/guidelines/INVARIANTS.md` |
| Quality standards | `spec/guidelines/QUALITY_BAR.md` |
| Product vision | `spec/guidelines/VISION.md` |
| Feature specs | `spec/features/` |
| Active work | `spec/work/` |
| Decisions & learnings | `spec/knowledge/` |

Guidelines are symlinked into `.cursor/rules/` and auto-load.

## File Ownership

| Path | Owner | AI May Modify |
|------|-------|---------------|
| `spec/guidelines/*` | Human | No |
| `spec/features/*` | Human | No (unless asked) |
| `spec/work/*.md` | AI | Yes |
| `spec/knowledge/*.md` | AI | Yes |
| `lib/`, `test/` | Shared | Yes |

## Key Commands

```bash
dart pub get
dart analyze
dart test
```

## Project Rules

- Follow Dart conventions in `.cursor/rules/dart.mdc`
