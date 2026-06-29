## Context

kql-guard is a ~460-line NativeAOT .NET 9 CLI. Its pipeline is: `KustoCode.Parse(text)` → run AST visitors → collect `Violation` records → print text or SARIF → exit (`0` clean, `1` findings, `2` usage). Two rules exist today: KQL001 (parser syntax diagnostics) and KQL002 (`contains` anti-pattern via `ContainsOperatorVisitor`, a `DefaultSyntaxVisitor`).

The FinOps Cost Profiler extends this offline engine with cost-oriented heuristics, a per-file score, and an opt-in budget gate. The defining constraint: **stay offline.** No DB connection, no Azure auth, no network — those would reintroduce exactly the CI fragility kql-guard exists to replace.

## Goals / Non-Goals

**Goals:**
- Add cost rules KQL003–KQL008 as AST visitors, reusing the existing `Violation` flow.
- Attach a relative, unitless cost weight to each cost finding; sum them into a per-file score.
- Add an opt-in `--max-cost <int>` gate that fails CI on breach.
- Report the score in text and SARIF without breaking SARIF validity.
- Define an `ICostEnricher` seam so future live-API enrichment slots in without refactoring.

**Non-Goals:**
- No live API calls, Azure auth, table sizing, or ingestion lookups (separate future change).
- No dollar/currency figures — impossible to compute honestly offline.
- No config file — a single flag suffices for v1.
- No new dependencies; remain NativeAOT-compatible (no reflection-based JSON, keep source-gen SARIF context).

## Decisions

**1. Cost weight lives on `Violation`, not a parallel structure.** Add an `int CostWeight` field to the `Violation` record (default 0 for KQL001 syntax errors). Scoring is then a trivial `Sum` per file. Alternative considered: a separate `costFindings` list keyed by file — rejected as redundant bookkeeping; the violations already carry file + rule, weight is one more field.

**2. Weights centralized in one table.** A single static map (rule ID → weight) is the "calibration knob." Heuristic rules will misfire; tuning must be a one-line edit, not a hunt across visitors. Each visitor reads its weight from this map.

**3. Rules are visitors, mirroring KQL002.** Most rules map cleanly to `Kusto.Language` syntax nodes:
- KQL004 `search` → `SearchOperator` with no name reference / `*`.
- KQL005 `union *` → `UnionOperator` with a wildcard operand.
- KQL006 `join` → `JoinOperator`; check neither operand subtree contains a time bound.
- KQL007 regex → `matches regex` binary expression + `FunctionCallExpression` named `extract`/`extract_all`/`parse`.
- KQL003 (missing time filter) and KQL008 (no reduction) are **whole-query** heuristics, not single-node: evaluate once per `KustoCode` by scanning for the presence/absence of `ago(`/`between`/datetime comparison (KQL003) and of any `project`/`project-away`/`summarize`/`take`/`limit` operator (KQL008). These run as a single pass over the statement's operator pipeline rather than per-node visits.

**4. One combined cost visitor + one query-level pass.** Rather than six visitor classes, use one `CostVisitor` for the node-local rules (KQL004–KQL007, plus the existing contains logic moved in or left as-is) and a small query-level function for KQL003/KQL008. Fewer files, same coverage. Alternative (one class per rule) rejected as scaffolding.

**5. SARIF score as run-level property.** SARIF `run.properties` is a free-form bag; emit `{"costScores": {"<path>": n}}`. This keeps the schema valid and avoids inventing a non-standard result field. Per-finding weights are not added to SARIF results in v1 (YAGNI; the rule ID implies severity).

**6. `ICostEnricher` is a one-method seam.** `int Adjust(string ruleId, int staticWeight, string? tableName)`. `NullCostEnricher` returns `staticWeight`. The scoring step calls it; with the null impl it's an identity pass-through. This is the only forward-looking abstraction, justified because retrofitting enrichment into scoring later would touch every call site. Single implementation today is acceptable precisely because the second (live) implementation is a known, planned change.

## Risks / Trade-offs

- **Heuristic false positives (KQL003, KQL006, KQL008)** → Centralized weights allow quick down-tuning; rules carry `warning` severity, not `error`; `ponytail:` comments document the ceiling. Users can ignore by not setting `--max-cost`.
- **AST node-kind assumptions may not match `Kusto.Language` exactly** → Verify actual `SyntaxKind`/node types against the installed `Kusto.Language` package during implementation (TDD: write the sample + assertion first, confirm the node match empirically).
- **`--max-cost` arg parsing bolted onto positional args** → The current parser is ad-hoc (`args[1]==--format`). Adding `--max-cost` means a small, deliberate parse pass over remaining args; keep it minimal but order-independent for the two flags.
- **Multi-statement `.kql` files** → Score is per-file (per `KustoCode`), matching today's whole-file parse. Acceptable; per-statement scoring is a future refinement if needed.

## Migration Plan

Additive change. No data migration. Rollback = revert the commit; existing KQL001/KQL002 behavior and exit codes are untouched. Default invocation (no `--max-cost`) is backward compatible except for additional findings and the new per-file score line in text output.

## Open Questions

None blocking. Live-API enrichment backend (ADX `.show table details` vs Log Analytics `Usage`/REST) is deferred to its own change and explicitly out of scope here.
