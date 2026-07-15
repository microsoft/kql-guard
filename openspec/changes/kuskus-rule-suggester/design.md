## Context

kql-guard is a ~1300-line NativeAOT .NET CLI whose rules — and their relative `CostWeight`s — are baked into the binary and authored by hand (`CostRules.cs`). Rule IDs: `KQL001` (syntax/parser), `KQL002`–`KQL013` (cost, advisory), `KQL101` (schema/binder). A rule is a tightly-templated unit: a `RuleInfo` entry in `Rules.All`, an AST-walk block in `CostAnalyzer.Analyze`, a `samples/cost/<name>.kql` fixture that triggers exactly one rule, and one `assert_contains` line in `test/run-tests.sh`.

**Kuskus is not a curated corpus of human detections — it is an Azure Data Explorer cluster whose `QueryCompletion` table is query *execution telemetry*.** A 100-row sample (`QueryCompletion | where Text != "[Redacted …]" | take 100`) shows the columns that matter here: `Text` (the query), and its measured cost — `Duration`, `TotalCPU`, `MemoryPeak`, and `ScannedExtentsStatistics` (`ScannedRowsCount`, `TotalRowsCount`, `ScannedExtentsCount`) — plus `State` (`Completed`/`Failed`) and `FailureReason` (e.g. `SEM0100: 'summarize' operator: Failed to resolve scalar expression named 'GrgIdentifier'`). 96 of 100 rows carried full scan stats; one query scanned 109,968,764 of 2,052,845,425 rows.

Two facts from the sample shape the design:

1. **The corpus is overwhelmingly machine-generated.** `request_app_name` is dominated by `TaskExecutor`, `ADF.ControlCommand`, `adxexporter`, Logic Apps, and dozens of `AzureSQLDB.Mon.*` runners; `WorkloadGroup` is 42 `Runners` / 18 `TaskExecutor` / 25 `HotCacheStandard`. Almost no interactive human authors. Mining this for *human* anti-patterns is low-yield without heavy filtering — but the **cost telemetry is authorship-agnostic**: an expensive query is expensive whoever wrote it.
2. **`Text` comes in two dialects.** An **expanded/internal** form — `["Col"]|project…|assert-schema(…)|where(__invoke("notnull",…))|summarize hint.strategy=…` — is the engine's post-optimizer serialization, which does **not** round-trip through `Kusto.Language` as authored KQL; and a **readable** form — `MonGRGActivity | where startTime > ago(30min) | summarize … by … | join …`. Only the readable dialect is lintable/minable.

This reframes the design around the corpus's strongest, best-grounded signal — **real execution cost** — rather than shape frequency. The confidentiality constraint is unchanged and, if anything, sharper: Kuskus is confidential, this repo will be public, so **raw corpus text never crosses from the runner into the public repository**; only aggregate numbers and abstracted shapes do.

## Goals / Non-Goals

**Goals:**
- A deterministic `kql-guard calibrate` that joins each rule's findings to the real per-query cost from `QueryCompletion` and emits an aggregate per-rule cost report + failure-catch coverage.
- A scheduled pipeline that reports existing-rule frequency + real cost, and opens **mechanical, human-reviewed** weight-adjustment PRs when a rule's real-cost rank disagrees with its declared `CostWeight`.
- Secondarily, a cost-ranked `kql-guard mine` over the readable dialect that surfaces recurring unflagged shapes for AI-drafted, fully-validated new-rule PRs.
- Strict confidentiality: only aggregate numbers, abstracted signatures, and leak-guard-passed diffs cross into the public repo; every automated step fails closed.

**Non-Goals:**
- No auto-merge and no auto-applied weight change — every rule/weight change is a PR a maintainer reviews.
- No live Kuskus access or specific AI endpoint in this change (shipped as contracts + stubs; real wiring is a later change).
- No new binary dependencies; both subcommands stay offline and NativeAOT-safe (source-gen JSON only).
- No dollar figures, no ML/semantic clustering in v1 — real cost aggregates + structural (AST-shape) clustering only.
- **No weight formula.** Real cost informs a *human review*; it does not deterministically compute a new weight (reasoning in Decision 2).

## Trust boundary (the backbone)

```
schedule / workflow_dispatch  ──►  self-hosted runner (in-boundary)
  ① fetch (stub)   watermark → pull QueryCompletion since it (skip Redacted + expanded dialect) → scratch/   (count only to logs)
  ② calibrate      kql-guard calibrate scratch/  → per-rule real-cost aggregates + failure-catch      (PRIMARY)
                   kql-guard <scratch> --format json │ jq  → existing-rule frequency histogram
  ③ weight review  rule cost-rank vs declared CostWeight disagrees → MECHANICAL one-line weight-edit diff (no AI)
  ④ mine (2nd)     readable-dialect, unflagged, cost-ranked shapes
  ⑤ AI draft (2nd) top-N shapes → in-boundary AI drafts a templated RuleInfo + Analyze block + SYNTHETIC sample + test
  ⑥ validate  FAIL-CLOSED   run-tests.sh + dotnet publish -c Release -r linux-x64 + over-report (<T%)
  ⑦ leak-guard FAIL-CLOSED  every outgoing diff shares NO token-shingle with scratch/
  ═══════════════════════ boundary ═══════════════════════
  ⑧ publish        job-summary (aggregate numbers) + idempotent review PRs (weight edits; new rules)
```

Everything above the boundary touches raw corpus text and runs only on the runner. What crosses below it is now **aggregate numbers** (the cost report / histogram) and diffs that passed validation + the leak-guard. Because the crossing payload is aggregates, **the boundary contract is invariant to input sensitivity**: granting the runner the *confidential* full-text `QueryCompletion` tier raises mining/calibration yield without changing what crosses — and makes the boundary more critical, so it stays strict now.

## Decisions

**1. Calibration is the primary capability; it reuses the analyzer and needs no AI.** The corpus's best-grounded signal is real cost, and correlating it with findings requires only: run the existing `CostAnalyzer` over each query, then aggregate that row's own `Duration`/`TotalCPU`/`MemoryPeak`/`ScannedRowsCount` per rule that fired. No model, no clustering — deterministic and unit-testable. *This is the part initially (wrongly) dismissed as "needs live cost data the corpus lacks"; the cost data is in the same row as the text.*

**2. Real cost informs weight *review*, it does not compute weights.** Frequency ≠ cost, and cost ≠ weight either: `CostWeight`s are deliberately relative/unitless (`CostRules.cs`), and a single query's cost depends on cache state (`HotCache` vs cold), data volume, and cluster load — e.g. the sampled 110M-row scan ran in 30 ms from hot cache. So calibrate emits the *distribution* and a *disagreement signal* (a rule's median-cost rank vs its weight rank); a maintainer decides. The PR proposes a concrete edit, but the human owns it. *Alternative rejected:* a formula mapping median duration → weight — spuriously precise given cache/volume variance.

**3. Weight-adjustment PRs are mechanical (no AI); only *new-rule* drafting uses AI.** Changing a `CostWeight` is a one-token edit to `CostRules.cs` — a deterministic script writes it, with the calibration evidence in the PR body. The AI is confined to the secondary mining path, where it drafts a templated `RuleInfo` + `Analyze` block + synthetic sample + test. This keeps the primary, high-value path fully deterministic and model-free.

**4. Dialect filter: calibrate/mine consume only the readable KQL dialect.** The expanded/internal form (`__invoke`, `["col"]`, `assert-schema`, no-space `|`) is the engine's post-optimizer serialization — it neither round-trips through `Kusto.Language` nor represents an author's choices, so its "anti-patterns" are the optimizer's. Detect it (marker scan: `__invoke(`, `["`, `assert-schema`, `$matchesregex`) and skip. Redacted rows (`Text == "[Redacted …]"`) are skipped at fetch. *Consequence for calibrate:* cost aggregates cover the readable, parseable subset — reported honestly as such (n, % skipped).

**5. Failure-catch is measured, honestly bounded by schema.** For `State == Failed` rows, calibrate runs the analyzer and reports what fraction of real `SYN`/`SEM` failures kql-guard would have flagged pre-execution (KQL001 catches syntax; KQL101 catches schema errors *when the schema is known*). Many `SEM` errors need table schema kql-guard does not have offline, so the report states the catchable vs schema-dependent split rather than implying full coverage.

**6. `mine` is secondary, cost-ranked, and its yield scales with corpus access.** Given the machine-generated skew, mining ranks recurring **unflagged** clusters (readable dialect, `WithExistingFinding == 0`) **by real cost** — an expensive recurring unflagged shape is a real rule candidate regardless of author. Its yield is contingent: today's redacted corpus limits it; a future confidential full-text tier is exactly when it becomes meaningful. So it ships behind the same fail-closed gates but with tempered expectations. *Alternative rejected:* frequency-only ranking — surfaces cheap boilerplate.

**7. AI drafts only a templated diff; validation is the gate, not trust.** (Secondary path.) The in-boundary AI (provider pluggable, Azure OpenAI in-tenant default) may touch only the four rule-template files; the pipeline applies the diff and requires `./test/run-tests.sh`, the NativeAOT release publish, and a `< T%` over-report check to pass. Any failure discards the candidate. The AI step is not deterministically unit-testable; its check *is* the validation gate.

**8. The leak-guard is what lets any AI-authored content cross the boundary.** Before crossing, the entire outgoing diff is shingled (whitespace-normalized k-token n-grams) and compared against every fetched query; any overlap blocks the candidate. Mechanical weight-edit PRs carry no query text and pass trivially, but the guard still runs on every outgoing diff.

**9. PRs are idempotent, fingerprinted.** Weight PRs fingerprint by rule ID (`kuskus/weight-<ruleId>`); new-rule PRs by shape signature (`kuskus/rule-<fingerprint>`). Skip if a PR/branch for that fingerprint exists or, for new rules, a rule already covers the shape. Fingerprints + watermark persist on the runner, never in the repo.

**10. Fetch + AI provider ship as contracts + stubs.** The real `QueryCompletion` fetch and the in-tenant AI endpoint need infra that does not exist yet; this change ships their contracts (documented I/O + a stub that fails with a clear message, and a local mock suggester for tests) so the pipeline runs end-to-end today against a `workflow_dispatch` `corpus_path`. Coordinates live in runner env/secrets, never committed. Deferrals are marked with `ponytail:` comments and a Placeholders section — visible, not hidden.

## Fetch contract (concrete; coordinates stay in runner secrets)

The fetch step (in-boundary, real impl deferred) pulls, per run:

```
cluster = kuskus   database = Kuskus   table = QueryCompletion
project Text, Duration, TotalCPU, MemoryPeak, ScannedExtentsStatistics, State, FailureReason, Timestamp
| where Timestamp > <watermark>
| where Text != "[Redacted - see confidential Kuskus for full trace]"
// runner-side: drop expanded-dialect rows (marker scan) → write scratch/<id>.json (one enriched row per query)
```

Watermark column: `Timestamp` (v1). The cluster/database/table strings and auth (managed identity) live in runner env/secrets — never committed. The confidential full-text tier, if granted, is the same contract against a more-privileged source; nothing downstream changes.

## Alternatives considered: relaxing the trust boundary

The strict boundary costs real machinery (an in-boundary model for the *secondary* path, synthetic examples, leak-guard). The **primary calibration path already crosses only aggregate numbers**, so it is safe under every row below; these relaxations only affect the secondary mining/AI path. Recorded so a future maintainer can revisit deliberately:

| Relaxation | What it unlocks | What it costs |
|------------|-----------------|---------------|
| **Leak 1 only** (query text → AI vendor OK) | any external frontier API + hosted embeddings (semantic clustering for mining); near-zero AI infra | still keep synthetic examples + leak-guard (repo still protected); detection logic goes to a third party |
| **Leak 2 only** (query text → public repo OK) | **real** corpus queries as fixtures/PR examples — delete synthetic-gen and the entire leak-guard | detection patterns become public; model stays in-tenant |
| **Both** ("easy mode") | external API + real examples; only over-report + `mine` remain | no confidentiality |

The over-report check and `mine`'s deterministic ranking are invariant across all four — quality gates, not secrecy gates. Architecturally the strict design is "easy mode + two isolated guardrails," so a future relaxation is a *deletion* (drop the in-boundary constraint and/or leak-guard), not a re-architecture. Committing to strict now costs nothing later.

## Risks

- **Cost variance misleads weight review.** Cache state / data volume / cluster load make single-query cost noisy. Mitigated by reporting distributions (median + p95) over the flagged population versus a no-findings baseline, never a point estimate, and by human-owned weight decisions.
- **Readable-subset bias.** Skipping the expanded dialect + redacted rows means aggregates cover a subset; a machine-heavy corpus may under-represent human patterns. Reported honestly (n, % skipped); the confidential tier widens coverage.
- **Failure-catch overclaim.** Schema-dependent `SEM` errors aren't catchable offline. Mitigated by splitting catchable (syntax / known-schema) from schema-dependent in the report.
- **Synthetic-example quality / signature over-collapsing / leak-guard false-negatives** (secondary path). Mitigated by the over-report check, mandatory human review, and defense in depth (in-boundary model + synthetic-only instruction + shingle scan). False *positives* (synthetic text incidentally overlapping) simply drop a candidate — safe.
