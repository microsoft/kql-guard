## 1. Scaffolding & weights

- [x] 1.1 Add `int CostWeight` field to the `Violation` record (default 0; KQL001 syntax errors stay 0).
- [x] 1.2 Add a single static `RuleWeights` map (rule ID → weight): KQL002=1, KQL003=5, KQL004=5, KQL005=4, KQL006=3, KQL007=2, KQL008=1. This is the "calibration knob" — annotate with a `ponytail:` comment.
- [x] 1.3 Define `ICostEnricher` with `int Adjust(string ruleId, int staticWeight, string? tableName)` and `NullCostEnricher` returning `staticWeight`. Wire `NullCostEnricher` as the default used by scoring.

## 2. Cost rules (TDD: add sample + assertion first, then implement)

- [x] 2.1 KQL004 — flag `search` with no table scope (`SearchOperator`, wildcard/no name ref). Add `samples/cost-search-star.kql` and assert it fires.
- [x] 2.2 KQL005 — flag wildcard `union` (`UnionOperator` with `*`/prefix wildcard operand). Add `samples/cost-union-star.kql` and assert.
- [x] 2.3 KQL006 — flag `join` where neither operand subtree is time-bounded. Add `samples/cost-unwindowed-join.kql` and assert.
- [x] 2.4 KQL007 — flag `matches regex` and `extract`/`extract_all`/`parse` regex calls. Add `samples/cost-regex.kql` and assert.
- [x] 2.5 KQL003 — query-level pass: flag a table query with no `ago()`/`between`/datetime comparison. `ponytail:` comment naming the false-positive ceiling. Add `samples/cost-no-timefilter.kql` and assert.
- [x] 2.6 KQL008 — query-level pass: flag a query with no `project`/`project-away`/`summarize`/`take`/`limit`. `ponytail:` comment. Add `samples/cost-no-reduction.kql` and assert.
- [x] 2.7 Fold existing KQL002 `contains` into the scoring model (weight 1 from `RuleWeights`); confirm it still fires.
- [x] 2.8 Verify each rule's AST node match against the installed `Kusto.Language` package empirically (the assertion in each sample is the check).

## 3. Scoring, reporting & gate

- [x] 3.1 Compute per-file cost score = sum of `CostWeight` over cost findings (KQL002–KQL008), routed through `ICostEnricher.Adjust`. KQL001 excluded.
- [x] 3.2 Text output: print one `<path>: cost score <n>` line per file.
- [x] 3.3 SARIF: add KQL003–KQL008 to driver `rules`; carry per-file scores in `run.properties.costScores` (keep schema valid, source-gen JSON context).
- [x] 3.4 Parse optional `--max-cost <int>` (order-independent alongside `--format sarif`); if any file score exceeds it, exit `1`. Preserve `0`/`1`/`2` semantics. Update usage text.

## 4. Verification

- [x] 4.1 Add a clean baseline `samples/cost-clean.kql` (time-bounded, scoped, reduced) and assert it produces no cost findings and scores 0.
- [x] 4.2 Self-check (assert-based `demo()`/test) covering: each rule fires on its sample, clean sample scores 0, score sums correctly, `--max-cost` breach exits non-zero, omitting the flag does not gate.
- [x] 4.3 Build NativeAOT and run the full `samples/` scan in text and `--format sarif`; validate SARIF parses.
- [x] 4.4 Update README with the new rules table, `--max-cost` flag, and the per-file score line.
