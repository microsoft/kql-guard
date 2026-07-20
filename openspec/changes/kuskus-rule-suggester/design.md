## Context

kql-guard is a ~1300-line NativeAOT .NET CLI whose rules — and their relative `CostWeight`s — are baked into the binary and authored by hand (`CostRules.cs`). Rule IDs: `KQL001` (syntax/parser), `KQL002`–`KQL013` (cost, advisory), `KQL101` (schema/binder). A rule is a tightly-templated unit: a `RuleInfo` entry in `Rules.All`, an AST-walk block in `CostAnalyzer.Analyze`, a `samples/cost/<name>.kql` fixture that triggers exactly one rule, and one `assert_contains` line in `test/run-tests.sh`. Its `--format json` output is a `JsonReport` whose `Findings[]` each carry `File`, `Rule`, and `CostWeight` (`SarifModels.cs`).

**Kuskus is not a curated corpus of human detections — it is an Azure Data Explorer cluster whose `QueryCompletion` table is query *execution telemetry*.** A 100-row sample (`QueryCompletion | where Text != "[Redacted …]" | take 100`) shows the columns that matter here: `Text` (the query), and its measured cost — `Duration`, `TotalCPU`, `MemoryPeak`, and `ScannedExtentsStatistics` (`ScannedRowsCount`, `TotalRowsCount`, `ScannedExtentsCount`) — plus `State` (`Completed`/`Failed`) and `FailureReason` (e.g. `SEM0100: 'summarize' operator: Failed to resolve scalar expression named 'GrgIdentifier'`). 96 of 100 rows carried full scan stats; one query scanned 109,968,764 of 2,052,845,425 rows.

Two facts from the sample shape the design:

1. **The corpus is overwhelmingly machine-generated.** `request_app_name` is dominated by `TaskExecutor`, `ADF.ControlCommand`, `adxexporter`, Logic Apps, and dozens of `AzureSQLDB.Mon.*` runners; `WorkloadGroup` is 42 `Runners` / 18 `TaskExecutor` / 25 `HotCacheStandard`. Almost no interactive human authors. Mining this for *human* anti-patterns is low-yield without heavy filtering — but the **cost telemetry is authorship-agnostic**: an expensive query is expensive whoever wrote it.
2. **`Text` comes in two dialects.** An **expanded/internal** form — `["Col"]|project…|assert-schema(…)|where(__invoke("notnull",…))|summarize hint.strategy=…` — is the engine's post-optimizer serialization, which does **not** round-trip through `Kusto.Language` as authored KQL; and a **readable** form — `MonGRGActivity | where startTime > ago(30min) | summarize … by … | join …`. Only the readable dialect is lintable/minable.

This reframes the design around the corpus's strongest, best-grounded signal — **real execution cost** — rather than shape frequency. The confidentiality constraint is unchanged and, if anything, sharper: Kuskus is confidential, this repo will be public, so **raw corpus text never crosses from the runner into the public repository**; only aggregate numbers and abstracted shapes do.

## Goals / Non-Goals

**Goals:**
- A deterministic calibration step that joins each rule's findings to the real per-query cost from `QueryCompletion` and emits an aggregate per-rule cost report + failure-catch coverage — with no new binary code and no AI.
- A scheduled pipeline that reports existing-rule frequency + real cost, and opens **mechanical, human-reviewed** weight-adjustment PRs when a rule's real-cost rank disagrees with its declared `CostWeight`.
- A cost-ranked mining step over the readable dialect that surfaces recurring unflagged shapes for AI-drafted, fully-validated new-rule PRs.
- Strict confidentiality, generic over trace tiers: only aggregate numbers, abstracted signatures, and leak-guard-passed diffs cross into the public repo; every automated step fails closed.

**Non-Goals:**
- No auto-merge and no auto-applied weight change — every rule/weight change is a PR a maintainer reviews.
- **No new subcommands.** The binary gains only a `--shapes` flag; calibration and mining are boundary-side scripts.
- No live Kuskus access or specific AI endpoint in this change (shipped as contracts + stubs; real wiring is a later change).
- No new binary dependencies; the `--shapes` output stays NativeAOT-safe (source-gen JSON only).
- No dollar figures, no ML/semantic clustering in v1 — real cost aggregates + structural (AST-shape) clustering only.
- **No weight formula.** Real cost informs a *human review*; it does not deterministically compute a new weight (reasoning in Decision 3).

## Trust boundary (the backbone)

```
schedule / workflow_dispatch  ──►  self-hosted runner (in-boundary)
  ① fetch (stub)      watermark → pull QueryCompletion since it (skip Redacted + expanded dialect)
                      → scratch/<id>.kql  +  cost manifest (<id> → duration,cpu,mem,scannedRows,state,failureReason)   (count only to logs)
  ② calibrate (script)  kql-guard scratch/ --format json  +  manifest  → per-rule real-cost aggregates + weight-disagreement + failure-catch   (PRIMARY)
                        (same JSON) │ jq  → existing-rule frequency histogram
  ③ weight review     rule cost-rank vs declared CostWeight disagrees → MECHANICAL one-line weight-edit diff (no AI)
  ④ mine (script)     kql-guard scratch/ --format json --shapes  +  manifest  → cluster unflagged shapes, rank by real cost
  ⑤ AI draft          top-N shapes → in-boundary AI drafts a templated RuleInfo + Analyze block + SYNTHETIC sample + test
  ⑥ validate  FAIL-CLOSED   run-tests.sh + dotnet publish -c Release -r linux-x64 + over-report (<T%)
  ⑦ leak-guard FAIL-CLOSED  every outgoing diff shares NO token-shingle with scratch/
  ═══════════════════════ boundary ═══════════════════════
  ⑧ publish           job-summary (aggregate numbers) + idempotent review PRs (weight edits; new rules)
```

Everything above the boundary touches raw corpus text and runs only on the runner. What crosses below it is **aggregate numbers** (the cost report / histogram), abstracted shape signatures, and diffs that passed validation + the leak-guard. Because the crossing payload is aggregates, **the boundary contract is invariant to input sensitivity**: whether the runner reads the confidential full-text `QueryCompletion` tier or a redacted trace view, what crosses is identical — so the boundary stays strict now and matters more, not less, with full-text access.

## Decisions

**1. No new subcommands; calibration and mining are boundary-side scripts.** `kql-guard scratch/ --format json` already emits, per finding, its `File`, `Rule`, and `CostWeight` (`SarifModels.cs`), and the pipeline already produces the `scratch/<id>.kql` files and runs that command (for the histogram and the leak-guard). So correlating findings with the fetch's cost manifest — per-rule cost aggregates, weight-rank vs cost-rank, failure-catch, shape clustering — is a small Python (stdlib-only) script. Baking a `calibrate`/`mine` verb into the public binary would add tool surface that a lint-in-CI user (who has no corpus and no cost telemetry) could never use, and would leak the confidential pipeline's shape into the public README.

**2. The one binary primitive: a per-query shape signature via `--shapes`.** Clustering needs the parsed AST, and a script cannot compute a robust signature without reinventing `Kusto.Language` (a regex over query text mis-clusters — KQL is not regex-parseable). The binary already parses every query to analyze it, so exposing that structure is nearly free: `kql-guard <path> --format json --shapes` adds a boundary-safe `{query-file → normalized signature}` map (operator/builtin kinds kept; identifiers, literals, user-defined function names stripped). This is a flag on the existing command, not a new subcommand; all clustering/ranking stays in the mining script.

**3. Real cost informs weight *review*, it does not compute weights.** Frequency ≠ cost, and cost ≠ weight either: `CostWeight`s are deliberately relative/unitless (`CostRules.cs`), and a single query's cost depends on cache state (`HotCache` vs cold), data volume, and cluster load — e.g. the sampled 110M-row scan ran in 30 ms from hot cache. So the calibration step emits the *distribution* and a *disagreement signal* (a rule's median-cost rank vs its weight rank); a maintainer decides. The PR proposes a concrete edit, but the human owns it. *Alternative rejected:* a formula mapping median duration → weight — spuriously precise given cache/volume variance.

**4. Weight-adjustment PRs are mechanical (no AI); only *new-rule* drafting uses AI.** Changing a `CostWeight` is a one-token edit to `CostRules.cs` — a deterministic script writes it, with the calibration evidence in the PR body. The AI is confined to the mining path, where it drafts a templated `RuleInfo` + `Analyze` block + synthetic sample + test. This keeps the primary, high-value path fully deterministic and model-free.

**5. Dialect filter: analyze only the readable KQL dialect.** The expanded/internal form (`__invoke`, `["col"]`, `assert-schema`, no-space `|`) is the engine's post-optimizer serialization — it neither round-trips through `Kusto.Language` nor represents an author's choices, so its "anti-patterns" are the optimizer's. The fetch drops it (marker scan: `__invoke(`, `["`, `assert-schema`, `$matchesregex`) and skips redacted rows (`Text == "[Redacted …]"`) before writing scratch. *Consequence:* aggregates cover the readable, parseable subset — reported honestly (n, % skipped).

**6. Generic over trace confidentiality; mining is in scope now.** We assume the runner has confidential full-text `QueryCompletion` access. The fetch contract, the `--shapes` primitive, and both scripts are identical whether the source is confidential full-text or a redacted trace view — confidentiality changes only which rows and how much text, not the code path. Full-text access raises mining yield (fewer redacted rows, more real shapes); the strict boundary holds either way. Given the machine-generated skew, mining ranks recurring **unflagged** clusters (readable dialect, no existing finding) **by real cost** — an expensive recurring unflagged shape is a real rule candidate regardless of author.

**7. AI drafts only a templated diff; validation is the gate, not trust.** The in-boundary AI (provider pluggable, Azure OpenAI in-tenant default) may touch only the four rule-template files; the pipeline applies the diff and requires `./test/run-tests.sh`, the NativeAOT release publish, and a `< T%` over-report check to pass. Any failure discards the candidate. The AI step is not deterministically unit-testable; its check *is* the validation gate.

**8. The leak-guard is what lets any AI-authored content cross the boundary.** Before crossing, the entire outgoing diff is shingled (whitespace-normalized k-token n-grams) and compared against every fetched query; any overlap blocks the candidate. Mechanical weight-edit PRs carry no query text and pass trivially, but the guard still runs on every outgoing diff.

**9. PRs are idempotent, fingerprinted.** Weight PRs fingerprint by rule ID (`kuskus/weight-<ruleId>`); new-rule PRs by shape signature (`kuskus/rule-<fingerprint>`). Skip if a PR/branch for that fingerprint exists or, for new rules, a rule already covers the shape. Fingerprints + watermark persist on the runner, never in the repo.

**10. Fetch + AI provider ship as contracts + stubs.** The real `QueryCompletion` fetch and the in-tenant AI endpoint need infra that does not exist yet; this change ships their contracts (documented I/O + a stub that fails with a clear message, and a local mock suggester for tests) so the pipeline runs end-to-end today against a `workflow_dispatch` `corpus_path`. Coordinates live in runner env/secrets, never committed. Deferrals are marked with `ponytail:` comments and a Placeholders section — visible, not hidden.

## Fetch contract (concrete; coordinates stay in runner secrets)

The fetch step (in-boundary, real impl deferred) pulls, per run:

```
// Query text is Customer Content → it exists ONLY on the confidential tier:
//   cluster  = https://kuskusheadconf.westeurope.kusto.windows.net   (PPE: kuskusseasppe.southeastasia)
//   database = Kuskus   table = QueryCompletion
// Column names/types below follow the $$QUERYCOMPLETION emitter
// (CommandOrQueryLoggingUtils.cs in Azure-Kusto-Service). ponytail: confirm
// with `QueryCompletion | getschema` on the live cluster before shipping the
// real fetch — the Kuskus KustoLogs update-policy parser isn't in source.
QueryCompletion
| where Timestamp > <watermark>
| where isnotempty(Text) and Text != "[Redacted - see confidential Kuskus for full trace]"
| project Text,
          durationMs      = totimespan(Duration) / 1ms,   // Duration is a timespan ('00:00:01.814')
          cpuMs           = TotalCPU / 1ms,               // TotalCPU is a timespan ('00:00:00.4567')
          memoryPeakBytes = MemoryPeak,                    // long, bytes
          scannedRows     = tolong(todynamic(ScannedExtentsStatistics).ScannedRowsCount),  // JSON string
          State, FailureReason, Timestamp
// NB: intentionally NOT filtered to State == "Completed" — calibration's
// failure-catch needs the Failed rows (text + FailureReason). Mining excludes
// Failed rows itself (see rule-mining "Shape clustering").
// runner-side: drop expanded-dialect rows (marker scan); per row write
//   scratch/<id>.kql          = Text
//   manifest[<id>]            = { durationMs, cpuMs, memoryPeakBytes, scannedRows, state, failureReason }
```

Watermark column: `Timestamp` (v1). The cluster/database/table strings and auth (managed identity) live in runner env/secrets — never committed. The confidential full-text tier and a redacted trace view are the same contract against different sources; nothing downstream changes.

**Fetch implementation note (deferred change).** kql-guard is NativeAOT, so the reflection-based `Microsoft.Azure.Kusto.Data` SDK cannot be embedded in the binary — the fetch stays a separate script. The reference connection idiom (`KustoConnectionStringBuilder(uri){ InitialCatalog = db }.WithAadSystemManagedIdentity()` → `KustoClientFactory.CreateCslQueryProvider` → `ExecuteQuery`) is the pattern to mirror, but the runner-side realization should hit the ADX REST API (`POST https://<cluster>/v2/rest/query`) with an IMDS managed-identity bearer token, or shell out to the Kusto CLI — no SDK dependency in kql-guard.

## Alternatives considered: relaxing the trust boundary

The strict boundary costs real machinery (an in-boundary model for the *mining* path, synthetic examples, leak-guard). The **calibration path already crosses only aggregate numbers**, so it is safe under every row below; these relaxations only affect the mining/AI path. Recorded so a future maintainer can revisit deliberately:

| Relaxation | What it unlocks | What it costs |
|------------|-----------------|---------------|
| **Leak 1 only** (query text → AI vendor OK) | any external frontier API + hosted embeddings (semantic clustering for mining); near-zero AI infra | still keep synthetic examples + leak-guard (repo still protected); detection logic goes to a third party |
| **Leak 2 only** (query text → public repo OK) | **real** corpus queries as fixtures/PR examples — delete synthetic-gen and the entire leak-guard | detection patterns become public; model stays in-tenant |
| **Both** ("easy mode") | external API + real examples; only over-report + the mining cluster script remain | no confidentiality |

The over-report check and the deterministic cost-ranking are invariant across all four — quality gates, not secrecy gates. Architecturally the strict design is "easy mode + two isolated guardrails," so a future relaxation is a *deletion* (drop the in-boundary constraint and/or leak-guard), not a re-architecture. Committing to strict now costs nothing later.

## Risks

- **Cost variance misleads weight review.** Cache state / data volume / cluster load make single-query cost noisy. Mitigated by reporting distributions (median + p95) over the flagged population versus a no-findings baseline, never a point estimate, and by human-owned weight decisions.
- **Readable-subset bias.** Skipping the expanded dialect + redacted rows means aggregates cover a subset; a machine-heavy corpus may under-represent human patterns. Reported honestly (n, % skipped); full-text access widens coverage.
- **Failure-catch overclaim.** Schema-dependent `SEM` errors aren't catchable offline. Mitigated by splitting catchable (syntax / known-schema) from schema-dependent in the report.
- **Synthetic-example quality / signature over-collapsing / leak-guard false-negatives** (mining path). Mitigated by the over-report check, mandatory human review, and defense in depth (in-boundary model + synthetic-only instruction + shingle scan). False *positives* (synthetic text incidentally overlapping) simply drop a candidate — safe.
