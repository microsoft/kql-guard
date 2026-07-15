## 1. `kql-guard calibrate` subcommand — PRIMARY (TDD: fixture + assertion first)

- [ ] 1.1 Add `calibrate` to the CLI dispatch alongside `fmt`/`pull` in `Program.cs`; parse `<path>`, `--format json` (default text). Usage errors exit `2`.
- [ ] 1.2 Corpus reader: read fetched `QueryCompletion` rows (one JSON object per query: `text` + `durationMs`, `cpuMs`, `memoryPeakBytes`, `scannedRows`, `state`, `failureReason`). Parse ADX `Duration`/`TotalCPU` timespan strings, comma-grouped `MemoryPeak`, and the `ScannedExtentsStatistics` JSON. One `[JsonSerializable]` input type on the source-gen context. `ponytail:` note — this reader is shared with `mine`.
- [ ] 1.3 Readable-dialect filter: skip expanded/internal rows (markers `__invoke(`, `["`, `assert-schema`, `$matchesregex`) and count them; skip parse failures (KQL001). Report skipped counts.
- [ ] 1.4 Correlate: run the existing `CostAnalyzer` per readable query; per rule ID aggregate `Count` + median/p95 of duration / scanned rows / CPU / memory over flagged queries; compute the same aggregates over the no-findings baseline.
- [ ] 1.5 Weight-disagreement: per cost rule compute its median-cost rank vs its `CostWeight` rank; flag material disagreements. **No new weight value is computed.**
- [ ] 1.6 Failure-catch: over `state == Failed` rows, run the analyzer; split catchable (syntax / known-schema) vs schema-dependent; report the fractions honestly.
- [ ] 1.7 Output: text table + JSON (source-gen context, no reflection). **No raw query text in either format.**
- [ ] 1.8 Self-check in `test/run-tests.sh` with a small synthetic fixture corpus (rows with known costs/states): a cheap-but-high-weight rule is flagged for review; a failed syntactic query counts as catchable; an expanded-dialect row is skipped and counted; JSON validates.
- [ ] 1.9 `dotnet publish -c Release -r linux-x64` succeeds with no reflection-JSON warnings; `README.md` documents `calibrate`.

## 2. Existing-rule frequency histogram (jq, no code)

- [ ] 2.1 A shell step that runs `kql-guard <corpus> --format json` and derives the histogram (rule ID → count) + totals via `jq`; render a markdown table into `$GITHUB_STEP_SUMMARY`. Aggregate stats and rule IDs only.
- [ ] 2.2 Self-check: feed a fixture `--format json` blob through the `jq` expression and assert the rendered counts.

## 3. Mechanical weight-review PR emitter (no AI)

- [ ] 3.1 `scripts/propose-weight.sh`: given a calibrate-flagged rule + evidence, deterministically edit **only** that rule's `CostWeight` in `CostRules.cs`; branch `kuskus/weight-<ruleId>`; PR body carries the cost aggregates; request review. Idempotent by rule ID.
- [ ] 3.2 Test: given a fixed calibrate finding, the script edits exactly one weight value and touches no other file; opening is skipped when a branch/PR for that rule ID exists.

## 4. Leak-guard (security path — TDD)

- [ ] 4.1 `scripts/leak-guard.sh <diff> <scratch-dir>`: whitespace-normalize, take k-token shingles (e.g. 8-grams) of every scratch query, and exit non-zero if any shingle appears anywhere in the diff. Runs on every outgoing diff.
- [ ] 4.2 Test: a diff containing a verbatim scratch query is blocked; a purely synthetic diff passes. This check must exist before any publish step is wired.

## 5. Validation gate (fail closed — for new-rule candidates)

- [ ] 5.1 `scripts/validate-candidate.sh`: apply the candidate diff on a fresh branch, run `./test/run-tests.sh`, run `dotnet publish -c Release -r linux-x64`, then build + run the new rule over the corpus and require it fires on `< T%` (configurable, default e.g. 20). Any failure exits non-zero → candidate discarded. Logs carry pass/fail + rule ID only.

## 6. `kql-guard mine` subcommand — SECONDARY (cost-ranked)

- [ ] 6.1 Shape signature: walk the parsed AST in source order; emit each node's syntax kind; keep function-call names only if they are `Kusto.Language` builtins else `<fn>`; normalize `NameReference` → `<id>` and literals → `<lit>`. One function, `ShapeSignature(KustoCode)`. `ponytail:` comment naming the single fixed normalization level.
- [ ] 6.2 Cluster: over the shared corpus reader (readable dialect only; skip expanded form + KQL001 parse failures), group by signature; per cluster compute `Count`, `WithExistingFinding` (existing `CostAnalyzer`), and a cost aggregate (e.g. median duration / scanned rows). Reuse `QueryExtraction`.
- [ ] 6.3 Output: rank clusters by real cost desc, take top-N; JSON `[{ "Shape", "Count", "WithExistingFinding", "MedianCost" }]` via a new `[JsonSerializable]` type (no reflection). Text mode prints a readable table. **No raw query text.**
- [ ] 6.4 Self-check in `test/run-tests.sh`: two queries identical in shape but differing in table/column/literal → one cluster (`Count` 2); a structurally different query → separate cluster; an already-flagged cluster reports `WithExistingFinding` > 0 while a clean-but-unflagged shape reports 0; the higher-cost cluster ranks first.
- [ ] 6.5 `dotnet publish -c Release -r linux-x64` clean; `README.md` documents `mine`.

## 7. AI suggester (contract + local mock; real provider deferred — secondary path)

- [ ] 7.1 Define the suggester I/O contract: input = top-N `mine` clusters + a few in-boundary example queries per shape; output = a unified diff touching only `CostRules.cs` (one `RuleInfo` + one `Analyze` block), `samples/cost/<name>.kql` (synthetic), and `test/run-tests.sh` (one assert). Document the prompt constraints (synthetic only, follow the rule template).
- [ ] 7.2 Ship a **local mock** suggester that emits a fixed, valid templated diff for a known shape, so stages 4–5 and 8 are testable end-to-end without a live model. `ponytail:` comment — swap the pluggable provider (Azure OpenAI in-tenant default) in the deferred change.

## 8. New-rule PR publishing + idempotency

- [ ] 8.1 `scripts/publish-candidate.sh`: fingerprint = hash of the shape signature; branch `kuskus/rule-<fingerprint>`. Skip if a rule already covers the shape or a PR/branch for that fingerprint exists (check via `gh`); else open/update a review PR whose body carries the abstracted shape, its frequency and cost, and the validated rule + synthetic tests. Persist proposed fingerprints on the runner.

## 9. Workflow + boundary wiring

- [ ] 9.1 `.github/workflows/kuskus-report.yml`: `schedule:` cron + `workflow_dispatch` (optional `corpus_path` input to bypass fetch); `runs-on:` the self-hosted runner label. Wire ① fetch → ② calibrate + histogram → ③ weight PRs → ④ mine → ⑤ AI suggest → ⑥ validate → ⑦ leak-guard → ⑧ publish, each gate fail-closed.
- [ ] 9.2 Ensure no query text reaches logs: capture kql-guard output to files, never echo scratch contents, `set +x` around query handling, secrets via managed identity / Actions secrets.
- [ ] 9.3 State on the runner: watermark file + proposed-fingerprints file, both outside the repo.

## 10. Deferred contracts (shipped as stubs in this change)

- [ ] 10.1 `scripts/fetch-corpus.sh` **stub**: documents the contract (cluster `kuskus`, database `Kuskus`, table `QueryCompletion`; project `Text` + the cost columns + `State`/`FailureReason`; watermark on `Timestamp`; skip `[Redacted …]` + expanded-dialect rows; write one enriched `scratch/<id>.json` per query; print count only; advance watermark on success; managed-identity auth) and fails with a clear "provide real fetch" message. Coordinates live in env/secrets. Real implementation is a separate change.
- [ ] 10.2 Add a "Placeholders" note (README or the workflow header) listing the two deferred integrations (real fetch, provider-specific AI wiring), and noting the primary calibration + weight path needs no AI and the pipeline runs today against a supplied `corpus_path` with the mock suggester.

## 11. Verification

- [ ] 11.1 `./test/run-tests.sh` passes (includes the new `calibrate`, weight-emitter, leak-guard, and `mine` checks); `dotnet publish -c Release -r linux-x64` clean.
- [ ] 11.2 End-to-end dry run: `workflow_dispatch` with a local sample `corpus_path` produces a job-summary cost report + a mechanical weight PR, and (with the mock suggester) a new-rule candidate that passes validate + leak-guard and opens a PR — with no raw query text anywhere in logs or PRs.
- [ ] 11.3 `openspec validate kuskus-rule-suggester --strict` passes.
