## Why

Misconfigured or unoptimized KQL queries are a leading cause of Azure Log Analytics / ADX cost spikes, and native Azure cost tooling only alerts *after* the money is spent. kql-guard already parses every query's AST offline in CI; extending that engine to flag financially dangerous query shapes turns cloud-cost management from a reactive alert into a proactive pull-request block — with zero new infrastructure, network calls, or secrets.

## What Changes

- Add a **static cost-profiling** pass to the existing AST analysis pipeline. New rules (KQL003–KQL008) flag high-cost query shapes, each carrying a relative **cost weight**.
- Compute a per-file **cost score** = sum of the weights of all findings in that file. The score is honest and unitless (no fabricated dollar figures, which are impossible offline).
- Fold the existing `contains` rule (KQL002) into the scoring model at a low weight.
- Add a `--max-cost <int>` flag (opt-in): if any file's score exceeds the budget, the tool exits non-zero, blocking the PR.
- Surface the score in both output formats: a per-file summary line in text mode, and a run-level property in SARIF.
- Define an `ICostEnricher` seam (default `NullCostEnricher`, no-op) so a future live-API enrichment change can adjust weights using real table sizes without refactoring. **No live API, auth, or network in this change.**

## Capabilities

### New Capabilities
- `cost-profiling`: Static, offline detection of high-cost KQL query shapes; per-finding cost weights, a per-file aggregate cost score, and an optional budget gate that fails CI when a score is exceeded.

### Modified Capabilities
<!-- No existing openspec specs yet (this is the first change); contains-rule behavior is incorporated under cost-profiling rather than as a separate delta. -->

## Impact

- **Code**: New visitor(s) and a scoring/aggregation step in `Program.cs`; new `ICostEnricher`/`NullCostEnricher`; SARIF rule metadata for KQL003–KQL008. Existing rules (KQL001 syntax, KQL002 contains) unchanged in behavior.
- **CLI surface**: New optional `--max-cost <int>` flag; new per-file score line in text output. Default behavior (no flag) is backward compatible aside from the additional findings.
- **Exit codes**: Unchanged semantics — `0` clean, `1` findings or budget breach, `2` usage error.
- **Dependencies**: None added. Still NativeAOT, .NET 9, offline, no DB connection.
- **Tests**: New `samples/*.kql` fixtures (one per rule + a clean-query baseline) and a self-check asserting each rule fires and a clean query scores 0.
