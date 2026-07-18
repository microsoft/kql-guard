## Why

kql-guard's rules — and their relative `CostWeight`s — are hand-authored. Nobody knows which rules actually flag *expensive* real-world queries, which are over-weighted or noisy, or which real failures the ruleset could have caught before execution. "Kuskus" is the evidence: an internal Microsoft Azure Data Explorer cluster whose `QueryCompletion` table records, for every executed query, its **text and its real execution cost** — `Duration`, `TotalCpuMs`, `MemoryPeak`, and scanned-rows/extents — plus success/failure and the failure reason.

That telemetry lets kql-guard's own findings be measured against ground truth: when a rule fires, were those queries actually expensive? This change mines that corpus on a cadence to **calibrate and validate the ruleset against real cost**, and to surface recurring unflagged query shapes as drafted rules. Kuskus is confidential and this repository will be public, so everything runs behind a strict trust boundary: only aggregate numbers and abstracted shapes ever cross into the public repo, never raw query text.

The analysis logic lives in the **boundary-side pipeline as scripts, not in the public binary**. `kql-guard --format json` already attributes every finding to its query file, rule, and `CostWeight`, so correlating findings with the fetched cost telemetry is a script — no new subcommand, no public tool surface that a lint-in-CI user could not use. The one thing a script cannot do is compute a robust AST shape signature (that needs the parser), so the binary gains a single `--shapes` flag.

## What Changes

- Add a **`--shapes` flag** to the existing analyze command: when set, `kql-guard <path> --format json --shapes` includes a boundary-safe, normalized per-query **shape signature** (operator/builtin kinds kept; identifiers, literals, and user-defined function names stripped) in its JSON. This is the only binary change and the only thing the parser must expose; it is a flag, not a new subcommand.
- Add a scheduled + `workflow_dispatch` pipeline on a self-hosted, in-boundary runner that:
  1. **fetches** new `QueryCompletion` rows since a watermark (skipping redacted text and the engine's expanded/internal dialect) into `scratch/<id>.kql` plus a per-query **cost manifest** (`<id>` → duration, CPU, memory, scanned-rows, state, failure-reason); nothing is logged,
  2. runs `kql-guard scratch/ --format json` once and a **calibration script** that correlates each rule's findings with the cost manifest → an aggregate per-rule cost report (count; median/p95 duration, scanned-rows, CPU, memory; versus a no-findings baseline) + a weight-disagreement signal + a failure-catch measurement; plus a `jq` existing-rule frequency histogram,
  3. opens **weight-review PRs**: when a rule's real-cost rank disagrees with its declared `CostWeight`, a **mechanical, deterministic** one-line weight edit is proposed for maintainer review (no AI, never auto-applied),
  4. runs a **mining script** over `kql-guard scratch/ --format json --shapes` + the cost manifest → clusters recurring *unflagged* shapes ranked **by real cost**, asks an in-boundary AI to draft a templated rule for the top-N, and runs it through the same fail-closed validation + leak-guard + idempotent-PR gates.
- Enforce a **strict trust boundary** whose crossing payload is *aggregate numbers* and abstracted shape signatures. The pipeline is **generic over trace confidentiality**: the fetch contract, the `--shapes` primitive, and the scripts are identical whether the source is confidential full-text `QueryCompletion` or redacted traces — confidentiality changes only which rows and how much text, never the code. The boundary matters more with full-text access, not less.
- Ship the **fetch** and **AI-suggester** as documented contracts + stubs; the pipeline runs end-to-end today against a supplied local corpus path with a mock suggester. The primary calibration + weight-review path needs no AI at all.

## Capabilities

### New Capabilities
- `rule-calibration`: A boundary-side calibration step that, from `kql-guard --format json` and the fetched cost manifest, correlates each rule's findings with the real per-query execution cost (duration, CPU, memory, scanned-rows) and measures failure-catch coverage — the deterministic engine that grounds `CostWeight`s and rule value in real numbers. No new binary code; no AI.
- `rule-suggester`: A scheduled, boundary-respecting pipeline that turns the calibration report into human-reviewed weight-adjustment PRs and machine-validated new-rule PRs — without exposing any raw corpus text.
- `rule-mining`: A `--shapes` primitive in the binary plus a boundary-side mining step that clusters readable-dialect corpus queries by normalized AST shape, ranks recurring *unflagged* clusters **by real cost**, and correlates each with existing findings.

## Impact

- **Code**: One new `--shapes` flag on the existing command (adds a boundary-safe per-query shape signature to the JSON via the source-gen context). No new subcommands. No existing rule *behaviour* changes; weight *values* change only via reviewed PRs.
- **CI / automation**: One new workflow (`.github/workflows/kuskus-report.yml`) plus small boundary-side scripts (fetch stub, calibration correlation script, mechanical weight-PR emitter, mining cluster script, AI-suggester contract + local mock, validation gate, leak-guard, PR publish), all kept **out** of the AOT binary.
- **Dependencies**: None added to the binary (still NativeAOT, offline, source-gen JSON). Scripts use `jq`, `git`, `gh`, and Python 3 stdlib (`json`, `statistics`) — all preinstalled on the runner; the AI provider (secondary path only) authenticates via managed identity.
- **Security**: Strict trust boundary; the crossing payload is aggregate numbers + abstracted shapes + leak-guard-passed diffs. Every gate fails closed. Watermark + proposed-candidate fingerprints live on the runner. Generic over trace confidentiality.
- **Deferred (separate changes)**: the real `QueryCompletion` fetch implementation and provider-specific AI wiring — contracts + stubs ship here so the pipeline runs end-to-end against a supplied corpus path today; the primary calibration path needs no AI.
