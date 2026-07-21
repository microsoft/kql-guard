# Ship the Azure OpenAI new-rule suggester (Approach A)

## Why

The mining path's new-rule drafter was deferred: `SUGGESTER_CMD` defaults to
`scripts/mock-suggester.py`, a hardcoded stub that always emits the same canned
`facet` rule regardless of the mined shape (this shipped the closed PR #38, whose
rule both mismatched the mined signature and collided on id KQL014). The
real-provider seam is documented but unbuilt.

## What Changes

- Add `scripts/aoai-suggester.py`: a stdlib-only Azure OpenAI adapter honoring
  the existing `suggest-rule.md` contract. IMDS-auth'd (runner MI), `json_schema`
  structured outputs, mechanical rule id from `CostRules.cs`, fail-closed
  validation. Reads only the masked signature on stdin (Approach A — no
  confidential access).
- Degrade the mining run to green when the (fail-closed) suggester exits nonzero:
  a job-summary skip line, not a `set -e` abort (calibration already ran).
- Provision the AOAI resource in `infra/terraform` (account + gpt-4o deployment +
  least-privilege role for the runner MI); surface the endpoint/deployment into
  the runner `.env`.
- Select the adapter on the runner via `SUGGESTER_CMD` in `kuskus-report.yml`;
  CI/self-tests keep the mock.

Out of scope (still deferred): feeding real query `Text`; the private endpoint +
Zero-Data-Retention that the real-text version requires.

## Impact

- Affected specs: `rule-suggester` (the "Deferred integrations shipped as
  contracts" requirement is now partially fulfilled — the AOAI drafter is
  shipped; real-text remains deferred).
- Affected code: `scripts/aoai-suggester.py` (new), `scripts/run-mining.sh`,
  `scripts/test_aoai_suggester.py` (new), `scripts/test_run_mining.sh`,
  `test/run-tests.sh`, `infra/terraform/*`, `.github/workflows/kuskus-report.yml`,
  `scripts/suggest-rule.md`.
