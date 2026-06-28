## Why

KQL style debates waste review time, and no canonical formatter exists for the community (the gap the README's roadmap names). The official `Kusto.Language` package already ships a deterministic formatter; exposing it as a `fmt` subcommand gives kql-guard a `gofmt`/`Prettier` equivalent for near-zero code.

## What Changes

- Add a `fmt` subcommand: `kql-guard fmt <path>` prints formatted KQL; `--write` rewrites files in place; `--check` exits 1 if any file is not already formatted (CI gate).
- Canonical one-pipe-per-line style via `Kusto.Language` (idempotent). No custom pretty-printer.
- Extract a shared `TryResolveFiles` helper reused by lint and fmt.

## Capabilities

### New Capabilities
- `formatting`: Deterministic, idempotent KQL formatting via stdout, in-place write, and a check gate.

## Impact

- New `Formatter.cs`; small dispatch + helper change in `Program.cs`. No new dependency (formatter is in the existing `Kusto.Language` package). Self-check and CI cover format/write/check + idempotency.
