## Why

kql-guard's rules are hand-authored, and today nobody knows which rules actually earn their keep against real-world KQL, nor which recurring anti-patterns the ruleset is still blind to. "Kuskus" — a large internal Microsoft corpus of Sentinel / hunting KQL — is exactly the evidence needed, but it is confidential and this repository is (soon) public, so it cannot simply be checked in or scanned in the open.

This change mines that corpus on a cadence to (1) report how often each existing rule fires and (2) surface recurring, currently-unflagged query shapes as **reviewed** pull requests that draft a new rule. It automates the toil (finding candidates, drafting the templated rule + tests, validating them) while keeping every rule change behind a human maintainer's review — and it does so behind a strict trust boundary so no raw corpus text ever leaves the runner.

## What Changes

- Add a `kql-guard mine <path> [--format json] [--top N]` subcommand. For each parser-clean query it computes a normalized **AST shape signature** (operator/builtin names kept; identifiers and literals stripped), groups queries by signature, ranks by frequency, and reports per cluster how many queries already produce an existing finding (`WithExistingFinding`). Output carries no raw query text.
- Add a scheduled + `workflow_dispatch` pipeline on a self-hosted runner that:
  1. **fetches** new Kuskus queries since a watermark into a scratch dir (never logged),
  2. writes an **existing-rule frequency report** (a `jq` histogram over `kql-guard --format json`, plus `mine`'s shape ranking) to the job summary,
  3. asks an **in-boundary AI** to draft a rule (a `RuleInfo` entry + an analyzer block + a **synthetic** sample + a test assertion) for the top-N frequent, unflagged shapes,
  4. **validates** each draft (`./test/run-tests.sh` + NativeAOT release publish + an over-report check), failing closed,
  5. runs a **leak-guard** (token-shingle scan) over the outgoing diff so no verbatim corpus text can cross the boundary,
  6. opens/updates an idempotent **review PR**.
- Enforce a **strict trust boundary**: raw corpus text never appears in logs, PRs, issues, or committed files; only aggregate stats, abstracted shape signatures, and leak-guard-passed diffs cross into the public repo.
- Ship the **fetch** and **AI-suggester** as documented contracts + stubs (real Kuskus access and the in-tenant AI endpoint are provisioned separately, in later changes).

## Capabilities

### New Capabilities
- `rule-mining`: An offline `kql-guard mine` subcommand that clusters a corpus of queries by normalized AST shape, ranks clusters by frequency, and correlates each cluster with existing findings — the deterministic engine that isolates recurring, currently-unflagged query shapes.
- `rule-suggester`: A scheduled, boundary-respecting pipeline that turns corpus mining into an existing-rule frequency report and human-reviewed, machine-validated pull requests proposing new rules, without exposing any raw corpus text.

## Impact

- **Code**: One new `mine` subcommand in the binary, reusing the existing parser, `QueryExtraction`, `CostAnalyzer`, and source-generated JSON context. No existing rules or analysis behavior change.
- **CI / automation**: One new workflow (`.github/workflows/kuskus-report.yml`) plus small pipeline scripts (fetch stub, AI-suggester contract + local mock, validation gate, leak-guard, PR publish) kept **out** of the AOT binary.
- **Dependencies**: None added to the binary (still NativeAOT, offline, no reflection JSON). Pipeline scripts use `jq` (preinstalled on runners), `git`, and `gh`; the AI provider authenticates via managed identity.
- **Security**: Strict trust boundary enforced by the leak-guard; every gate fails closed. Watermark + proposed-candidate fingerprints live on the runner, never in the public repo.
- **Deferred (separate changes)**: the real Kuskus fetch implementation and provider-specific AI wiring — their contracts + stubs ship here so the pipeline is runnable end-to-end against a supplied local corpus today.
