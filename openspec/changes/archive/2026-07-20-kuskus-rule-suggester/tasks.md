## 1. `--shapes` flag (the only binary change; TDD: fixture + assertion first)

- [x] 1.1 Add a `--shapes` flag to the existing analyze command in `Program.cs` (works with `--format json`). No new subcommand.
- [x] 1.2 Shape signature: walk the parsed AST in source order; emit each node's syntax kind; keep function-call names only if they are `Kusto.Language` builtins else `<fn>`; normalize `NameReference` → `<id>` and literals → `<lit>`. One function, `ShapeSignature(KustoCode)`. `ponytail:` comment naming the single fixed normalization level. Reuse the parse the analyzer already performs.
- [x] 1.3 Output: add a `Shapes` map (query-file → signature) to `JsonReport`, populated only when `--shapes` is set; register it on the source-gen `KqlGuardSarifContext` (no reflection). Omit queries that fail to parse. **No raw query text.**
- [x] 1.4 Self-check in `test/run-tests.sh`: two queries identical in shape but differing in table/column/literal → identical signature; a structurally different query → different signature; the signature contains no identifiers/literals.
- [x] 1.5 `dotnet publish -c Release -r linux-x64` succeeds with no reflection-JSON warnings; `README.md` documents `--shapes`.

## 2. Existing-rule frequency histogram (jq, no code)

- [x] 2.1 A shell step that runs `kql-guard <corpus> --format json` and derives the histogram (rule ID → count) + totals via `jq`; render a markdown table into `$GITHUB_STEP_SUMMARY`. Aggregate stats and rule IDs only. — Delivered inside `calibrate.py` as the "| Rule | Fires | … |" markdown table (`calibrate.py:127`), not a separate `jq` step: it already parses the same JSON, so a parallel jq path would be redundant (YAGNI). Aggregates + rule IDs only.
- [x] 2.2 Self-check: feed a fixture `--format json` blob through the `jq` expression and assert the rendered counts. — Covered by `test_calibrate.py` asserting the rendered Fires/median values from a fixture findings+manifest.

## 3. Calibration correlation script (Python stdlib; PRIMARY)

- [x] 3.1 `scripts/calibrate.py` (stdlib `json`, `statistics` only): read `kql-guard scratch/ --format json` (Findings: File, Rule, CostWeight) + the fetch cost manifest (`<id>` → durationMs, cpuMs, memoryPeakBytes, scannedRows, state, failureReason). Join finding.File ↔ manifest id.
- [x] 3.2 Per rule ID aggregate `Count` + median/p95 of duration / scanned rows / CPU / memory over flagged queries; compute the same aggregates over the no-findings baseline.
- [x] 3.3 Weight-disagreement: per cost rule compute its median-cost rank vs its `CostWeight` rank (both available from the JSON); flag material disagreements. **No new weight value is computed.**
- [x] 3.4 Failure-catch: over manifest `state == Failed` rows, check whether the query produced a syntax (KQL001) or schema (KQL101) finding; split catchable (syntax / known-schema) vs schema-dependent (classify the `failureReason` string); report the fractions honestly.
- [x] 3.5 Output: aggregate report (markdown for the job summary + JSON), rule IDs + numbers only, **no raw query text**. Works identically on confidential full-text or redacted traces.
- [x] 3.6 Self-check `scripts/test_calibrate.py` (asserts, no framework): a tiny fixture of findings + a manifest with known costs → a cheap-but-high-weight rule is flagged; a failed syntactic query counts catchable; medians/p95 are correct.

## 4. Mechanical weight-review PR emitter (no AI)

- [x] 4.1 `scripts/propose-weight.sh`: given a calibrate-flagged rule + evidence, deterministically edit **only** that rule's `CostWeight` in `CostRules.cs`; branch `kuskus/weight-<ruleId>`; PR body carries the cost aggregates; request review. Idempotent by rule ID.
- [x] 4.2 Test: given a fixed calibrate finding, the script edits exactly one weight value and touches no other file; opening is skipped when a branch/PR for that rule ID exists.

## 5. Leak-guard (security path — TDD)

- [x] 5.1 `scripts/leak-guard.sh <diff> <scratch-dir>`: whitespace-normalize, take k-token shingles (e.g. 8-grams) of every scratch query, and exit non-zero if any shingle appears anywhere in the diff. Runs on every outgoing diff.
- [x] 5.2 Test: a diff containing a verbatim scratch query is blocked; a purely synthetic diff passes. This check must exist before any publish step is wired.

## 6. Validation gate (fail closed — for new-rule candidates)

- [x] 6.1 `scripts/validate-candidate.sh`: apply the candidate diff on a fresh branch, run `./test/run-tests.sh`, run `dotnet publish -c Release -r linux-x64`, then build + run the new rule over the corpus and require it fires on `< T%` (configurable, default e.g. 20). Any failure exits non-zero → candidate discarded. Logs carry pass/fail + rule ID only.

## 7. Mining cluster script (Python stdlib)

- [x] 7.1 `scripts/mine.py` (stdlib only): read `kql-guard scratch/ --format json --shapes` (Shapes: file → signature; Findings for `WithExistingFinding`) + the cost manifest. Group readable-dialect queries by identical signature.
- [x] 7.2 Per cluster compute `Count`, `WithExistingFinding`, and a cost aggregate (median duration / scanned rows); rank clusters by real cost desc; take top-N; isolate `WithExistingFinding == 0`. Emit JSON + a job-summary table; **no raw query text**. — Job summary is an aggregate cluster list (count/median/abstract-signature, no raw text) tee'd to `$GITHUB_STEP_SUMMARY` by `run-mining.sh`, rendered as bullets rather than a pipe-table.
- [x] 7.3 Self-check `scripts/test_mine.py`: identical-shape queries cluster (Count 2); different shape → separate; an already-flagged cluster reports `WithExistingFinding` > 0 while a clean-but-unflagged shape reports 0; a higher-cost cluster ranks above a cheap frequent one.

## 8. AI suggester (contract + local mock; real provider deferred)

- [x] 8.1 Define the suggester I/O contract: input = top-N `mine.py` clusters + a few in-boundary example queries per shape; output = a unified diff touching only `CostRules.cs` (one `RuleInfo` + one `Analyze` block), `samples/cost/<name>.kql` (synthetic), and `test/run-tests.sh` (one assert). Document the prompt constraints (synthetic only, follow the rule template).
- [x] 8.2 Ship a **local mock** suggester that emits a fixed, valid templated diff for a known shape, so stages 5–6 and 9 are testable end-to-end without a live model. `ponytail:` comment — swap the pluggable provider (Azure OpenAI in-tenant default) in the deferred change.

## 9. New-rule PR publishing + idempotency

- [x] 9.1 `scripts/publish-candidate.sh`: fingerprint = hash of the shape signature; branch `kuskus/rule-<fingerprint>`. Skip if a rule already covers the shape or a PR/branch for that fingerprint exists (check via `gh`); else open/update a review PR whose body carries the abstracted shape, its frequency and cost, and the validated rule + synthetic tests. Persist proposed fingerprints on the runner. — The durable fingerprint is the `kuskus/rule-<fp>` branch itself + a `git ls-remote`/open-PR check (the actual cross-run idempotency signal), so no separate on-runner fingerprints file is needed.

## 10. Workflow + boundary wiring

- [x] 10.1 `.github/workflows/kuskus-report.yml`: `schedule:` cron + `workflow_dispatch` (optional `corpus_path` input to bypass fetch); `runs-on:` the self-hosted runner label. Wire ① fetch → ② calibrate.py + histogram → ③ weight PRs → ④ mine.py → ⑤ AI suggest → ⑥ validate → ⑦ leak-guard → ⑧ publish, each gate fail-closed. — Realized as two jobs (`calibrate`, `mine` with `needs: calibrate`), each calling an orchestrator (`run-calibration.sh` = ①②③, `run-mining.sh` = ④⑤⑥⑦⑧); every gate is fail-closed via `set -e` + non-zero exits, and leak-guard runs first inside `validate-candidate.sh`.
- [x] 10.2 Ensure no query text reaches logs: capture kql-guard output to files, never echo scratch contents, `set +x` around query handling, secrets via managed identity / Actions secrets. — Enforced by design: kql-guard output is captured to files and only aggregates are printed; scratch text is never echoed and leak-guard is the last check, so no literal `set +x` is required.
- [ ] 10.3 State on the runner: watermark file + proposed-fingerprints file, both outside the repo. — Proposed-fingerprints are realized via the branch/PR (§9.1). The watermark file is part of the deferred real-fetch contract (§11.1, "advance watermark on success") and is intentionally NOT shipped in this change.

## 11. Deferred contracts (shipped as stubs in this change)

- [x] 11.1 `scripts/fetch-corpus.sh` **stub**: documents the contract (cluster `kuskus`, database `Kuskus`, table `QueryCompletion`; project `Text` + cost columns + `State`/`FailureReason`; watermark on `Timestamp`; skip `[Redacted …]` + expanded-dialect rows; write `scratch/<id>.kql` + the cost manifest; print count only; advance watermark on success; managed-identity auth; identical for confidential full-text or redacted traces) and fails with a clear "provide real fetch" message. Coordinates live in env/secrets. Real implementation is a separate change.
- [x] 11.2 Add a "Placeholders" note (README or the workflow header) listing the two deferred integrations (real fetch, provider-specific AI wiring), and noting the primary calibration + weight path needs no AI and the pipeline runs today against a supplied `corpus_path` with the mock suggester.

## 12. Verification

- [x] 12.1 `./test/run-tests.sh` passes (includes the new `--shapes` check); the Python self-checks (`test_calibrate.py`, `test_mine.py`) and shell tests (weight emitter, leak-guard) pass; `dotnet publish -c Release -r linux-x64` clean.
- [x] 12.2 End-to-end dry run: `workflow_dispatch` with a local sample `corpus_path` produces a job-summary cost report + a mechanical weight PR, and (with the mock suggester) a new-rule candidate that passes validate + leak-guard and opens a PR — with no raw query text anywhere in logs or PRs.
- [x] 12.3 `openspec validate kuskus-rule-suggester --strict` passes.
