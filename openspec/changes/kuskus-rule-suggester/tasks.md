## 1. `kql-guard mine` subcommand (TDD: sample + assertion first)

- [ ] 1.1 Add `mine` to the CLI dispatch alongside `fmt`/`pull` in `Program.cs`; parse `<path>`, `--format json` (default text), `--top N` (default e.g. 20). Usage errors exit `2`.
- [ ] 1.2 Shape signature: walk the parsed AST in source order; emit each node's syntax kind; keep function-call names only if they are `Kusto.Language` builtins else `<fn>`; normalize `NameReference` → `<id>` and literals → `<lit>`. One function, `ShapeSignature(KustoCode)`. `ponytail:` comment naming the single fixed normalization level.
- [ ] 1.3 Cluster: group parser-clean queries (skip KQL001 parse failures) by signature; per cluster compute `Count` and `WithExistingFinding` (run the existing `CostAnalyzer` and count members with ≥1 finding). Reuse `QueryExtraction` so `.kql` and Sentinel `.yaml` are both handled.
- [ ] 1.4 Output: rank clusters by `Count` desc, take top-N. JSON `[{ "Shape", "Count", "WithExistingFinding" }]` via a new `[JsonSerializable]` type on the source-gen context (no reflection). Text mode prints a readable table. **No raw query text in either format.**
- [ ] 1.5 Self-check in `test/run-tests.sh`: two queries identical in shape but differing in table/column/literal → same signature (one cluster, `Count` 2); a structurally different query → separate cluster; a cluster of already-flagged queries reports `WithExistingFinding` > 0 while a clean-but-unflagged shape reports 0.
- [ ] 1.6 `dotnet publish -c Release -r linux-x64` succeeds with no reflection-JSON warnings; `README.md` documents the `mine` subcommand.

## 2. Existing-rule frequency report (jq, no code)

- [ ] 2.1 A shell step that runs `kql-guard <corpus> --format json` and derives the histogram (rule ID → count), totals, and summed cost via `jq`; render a markdown table into `$GITHUB_STEP_SUMMARY`. Emit aggregate stats and rule IDs only.
- [ ] 2.2 Self-check: feed a fixture `--format json` blob through the `jq` expression and assert the rendered counts (a small `test/` script; the money/aggregation path gets one runnable check).

## 3. Leak-guard (security path — TDD)

- [ ] 3.1 `scripts/leak-guard.sh <diff> <scratch-dir>`: whitespace-normalize, take k-token shingles (e.g. 8-grams) of every scratch query, and exit non-zero if any shingle appears anywhere in the diff. Blocks on overlap.
- [ ] 3.2 Test: a diff containing a verbatim scratch query is blocked; a purely synthetic diff passes. This check must exist before any publish step is wired.

## 4. Validation gate (fail closed)

- [ ] 4.1 `scripts/validate-candidate.sh`: apply the candidate diff on a fresh branch, run `./test/run-tests.sh`, run `dotnet publish -c Release -r linux-x64`, then build+run the new rule over the corpus and require it fires on `< T%` (configurable, default e.g. 20). Any failure exits non-zero → candidate discarded. Logs carry pass/fail + rule ID only.

## 5. AI suggester (contract + local mock; real provider deferred)

- [ ] 5.1 Define the suggester I/O contract: input = top-N `mine` clusters + a few in-boundary example queries per shape; output = a unified diff touching only `CostRules.cs` (one `RuleInfo` + one `Analyze` block), `samples/cost/<name>.kql` (synthetic), and `test/run-tests.sh` (one assert). Document the prompt constraints (synthetic only, follow the rule template).
- [ ] 5.2 Ship a **local mock** suggester that emits a fixed, valid templated diff for a known shape, so stages 3–4 and 6 are testable end-to-end without a live model. `ponytail:` comment: swap the pluggable provider (Azure OpenAI in-tenant default) in the deferred change.

## 6. PR publishing + idempotency

- [ ] 6.1 `scripts/publish-candidate.sh`: fingerprint = hash of the shape signature; branch `kuskus/rule-<fingerprint>`. Skip if a rule already covers the shape or a PR/branch for that fingerprint exists (check via `gh`); else open/update a review PR whose body carries the abstracted shape, frequency, and the validated rule + synthetic tests. Persist proposed fingerprints on the runner.

## 7. Workflow + boundary wiring

- [ ] 7.1 `.github/workflows/kuskus-report.yml`: `schedule:` cron + `workflow_dispatch` (optional `corpus_path` input to bypass fetch); `runs-on:` the self-hosted runner label. Wire ① fetch → ② report+mine → ③ suggest → ④ validate → ⑤ leak-guard → ⑥ publish, each gate fail-closed.
- [ ] 7.2 Ensure no query text reaches logs: capture kql-guard output to files, never echo scratch contents, `set +x` around query handling, secrets via managed identity / Actions secrets.
- [ ] 7.3 State on the runner: watermark file + proposed-fingerprints file, both outside the repo.

## 8. Deferred contracts (shipped as stubs in this change)

- [ ] 8.1 `scripts/fetch-corpus.sh` **stub**: documents the contract (read watermark → pull Kuskus since it → write `scratch/<id>.kql`, print count only, advance watermark on success, managed-identity auth) and fails with a clear "provide real fetch" message. Real implementation is a separate change (needs provisioned corpus access).
- [ ] 8.2 Add a "Placeholders" note (README or the workflow header) listing the two deferred integrations (real fetch, provider-specific AI wiring) and that the pipeline runs today against a supplied `corpus_path` with the mock suggester.

## 9. Verification

- [ ] 9.1 `./test/run-tests.sh` passes (includes the new `mine` and leak-guard checks); `dotnet publish -c Release -r linux-x64` clean.
- [ ] 9.2 End-to-end dry run: `workflow_dispatch` with a local sample `corpus_path` + the mock suggester produces a job-summary histogram and a candidate that passes validate + leak-guard and opens a PR — with no raw query text anywhere in logs or the PR.
- [ ] 9.3 `openspec validate kuskus-rule-suggester --strict` passes.
