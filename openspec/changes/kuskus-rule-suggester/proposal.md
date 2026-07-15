## Why

kql-guard's rules — and their relative `CostWeight`s — are hand-authored. Nobody knows which rules actually flag *expensive* real-world queries, which are over-weighted or noisy, or which real failures the ruleset could have caught before execution. "Kuskus" is the evidence: an internal Microsoft Azure Data Explorer cluster whose `QueryCompletion` table records, for every executed query, its **text and its real execution cost** — `Duration`, `TotalCPU`, `MemoryPeak`, and scanned-rows/extents — plus success/failure and the failure reason.

That telemetry lets kql-guard's own findings be measured against ground truth: when a rule fires, were those queries actually expensive? This change mines that corpus on a cadence to **calibrate and validate the ruleset against real cost**, and — secondarily — to surface recurring unflagged query shapes as drafted rules. Kuskus is confidential and this repository will be public, so everything runs behind a strict trust boundary: only aggregate numbers and abstracted shapes ever cross into the public repo, never raw query text.

## What Changes

- Add a **`kql-guard calibrate`** subcommand (primary). It reads fetched `QueryCompletion` rows (query text + real cost columns), runs the **existing analyzer in-process** over each parseable query, and correlates each rule's findings with the real execution cost of the queries that triggered it — emitting an **aggregate per-rule cost report** (firing count; median/p95 duration, scanned-rows, CPU, memory; versus a no-findings baseline). It also measures **failure-catch**: of the real `Failed` queries, what fraction kql-guard would have flagged pre-execution. Output carries no raw query text.
- Add a scheduled + `workflow_dispatch` pipeline on a self-hosted, in-boundary runner that:
  1. **fetches** new `QueryCompletion` rows since a watermark (skipping redacted text and the engine's expanded/internal query dialect) into a scratch dir (never logged),
  2. runs `calibrate` → writes the aggregate cost report + an existing-rule frequency histogram to the job summary,
  3. opens **weight-review PRs**: when a rule's real-cost rank disagrees with its declared `CostWeight`, a **mechanical, deterministic** one-line weight edit is proposed for maintainer review (no AI, never auto-applied),
  4. **secondarily** ranks recurring *unflagged* shapes (`kql-guard mine`, now cost-ranked and filtered to the human-authored dialect), asks an in-boundary AI to draft a templated rule for the top-N, and runs it through the same fail-closed validation + leak-guard + idempotent-PR gates.
- Enforce a **strict trust boundary** whose crossing payload is now *aggregate numbers* and abstracted signatures — invariant to how sensitive the input is, so a future upgrade to confidential full-text `QueryCompletion` increases yield without changing the design (and makes the boundary *more* important, not less).
- Ship the **fetch** and **AI-suggester** as documented contracts + stubs; the pipeline runs end-to-end today against a supplied local corpus path with a mock suggester. The primary calibration path needs no AI at all.

## Capabilities

### New Capabilities
- `rule-calibration`: An offline `kql-guard calibrate` subcommand that correlates each rule's findings with the real per-query execution cost from `QueryCompletion` (duration, CPU, memory, scanned-rows) and measures failure-catch coverage — the deterministic engine that grounds `CostWeight`s and rule value in real numbers.
- `rule-suggester`: A scheduled, boundary-respecting pipeline that turns the calibration report into human-reviewed weight-adjustment PRs and, secondarily, machine-validated new-rule PRs — without exposing any raw corpus text.
- `rule-mining`: A secondary, offline `kql-guard mine` subcommand that clusters human-authored-dialect corpus queries by normalized AST shape, ranks recurring *unflagged* clusters **by real cost**, and correlates each with existing findings.

## Impact

- **Code**: Two new subcommands (`calibrate` primary, `mine` secondary) reusing the existing parser, `QueryExtraction`, `CostAnalyzer`, and source-generated JSON context. No existing rule *behaviour* changes; weight *values* change only via reviewed PRs.
- **CI / automation**: One new workflow (`.github/workflows/kuskus-report.yml`) plus small pipeline scripts (fetch stub, mechanical weight-PR emitter, AI-suggester contract + local mock, validation gate, leak-guard, PR publish), kept **out** of the AOT binary.
- **Dependencies**: None added to the binary (still NativeAOT, offline, source-gen JSON). Pipeline scripts use `jq`, `git`, and `gh`; the AI provider (secondary path only) authenticates via managed identity.
- **Security**: Strict trust boundary; the crossing payload is aggregate numbers + leak-guard-passed diffs. Every gate fails closed. Watermark + proposed-candidate fingerprints live on the runner, never in the public repo.
- **Deferred (separate changes)**: the real `QueryCompletion` fetch implementation and provider-specific AI wiring — their contracts + stubs ship here so the pipeline is runnable end-to-end against a supplied corpus path today; the primary calibration path needs no AI.
