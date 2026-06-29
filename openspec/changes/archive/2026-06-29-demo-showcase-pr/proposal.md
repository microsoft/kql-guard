## Why

Highest-level managers need to *see* kql-guard, not read about it. Every feature surfaces on a single open Pull Request: inline SARIF code-scanning alerts, a failing cost-gate check, a schema (KQL101) error, and a formatter diff. microsoft/kql-guard is public, so code scanning renders inline annotations for free. One realistic detection rule that's deliberately expensive, misformatted, and schema-invalid demos the whole platform live.

## What Changes

- Add `demo/detections/SuspiciousSignin.kql` — one realistic Sentinel rule that is misformatted, uses `contains` + no time filter (cost rules), and references a typo'd column (KQL101). One file, five findings.
- Add `demo/schema.json` — minimal SigninLogs schema so KQL101 fires.
- Extend the existing CI workflow with visible demo steps over `demo/`: SARIF inline alerts, `--max-cost` gate (red ✗), `--schema` (KQL101), `fmt --check` (diff). Existing product scan untouched.
- Demo-only: lives in `demo/`, never referenced by the product. Baseline-only-new narrated in the PR body, not built (needs two commits to matter).

## Capabilities

### New Capabilities
- `demo-showcase`: A self-contained PR fixture that exercises every kql-guard feature live for stakeholders.

## Impact

- New `demo/` dir + extra CI steps in `.github/workflows/test-action.yml`. No product code changes. Self-check unaffected; the workflow run on the PR is the verification.
