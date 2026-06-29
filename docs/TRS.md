# kql-guard — Technical Requirements Specification (TRS)

## 1. Platform

- Language/runtime: C# on **.NET 8**, `PublishAot=true`, `InvariantGlobalization`.
- Dependency: `Microsoft.Azure.Kusto.Language` 12.3.2 (offline parser/formatter).
- Build: `dotnet publish -c Release -r linux-x64` → self-contained native binary.
- Test: `./test/run-tests.sh` (framework-free golden checks). No live cluster.

## 2. Source layout

| File | Responsibility |
|------|----------------|
| `Program.cs` | Arg parsing, file resolution, scoring, text/SARIF/JSON output, dispatch. |
| `CostRules.cs` | `Rules.All` registry, `ICostEnricher`/`NullCostEnricher`/`TableSizeEnricher`, `CostAnalyzer`. |
| `Suppressions.cs` | Line-scan suppression directives, filter findings. |
| `QueryExtraction.cs` | Lift KQL from `.kql` directly or from a Sentinel `.yaml` `query:` block, with line offset. |
| `SchemaLoader.cs` | Build a GlobalState from JSON schema; opt-in semantic validation via ParseAndAnalyze. |
| `Formatter.cs` | `fmt` via `KustoCodeService.GetFormattedText` (pipe-per-line, idempotent). |
| `SarifModels.cs` | SARIF v2.1.0 + JSON DTOs, source-gen `JsonSerializerContext` (AOT-safe). |
| `action.yml`, `Dockerfile` | GitHub Action + container distribution. |

## 3. Analysis design

- AST obtained via `KustoCode.Parse`; rules traverse using `GetDescendants<T>()`.
- Detection signals: `SearchOperator.InClause==null`; `UnionOperator`+`WildcardedName`;
  `MatchesRegexExpression`; `FunctionCallExpression.Name.SimpleName` for `extract`,
  `cluster`, `database`; `ContainsExpression`/`ContainsCsExpression`; `ago()`/`between`
  as time bounds; `MvExpandOperator` without `limit`; reducer operators by type name.
- All weights live in one table (`Rules.All`) — single tuning knob.
- Cost rules run even with syntax errors *off* (skipped when KQL001 present).

## 4. Scoring & enrichment

- File score = Σ finding weights, excluding KQL001.
- `--max-cost` compares per-file score; breach → exit 1.
- `--table-sizes` JSON `{table:factor}` multiplies KQL003/008 weights via `TableSizeEnricher`.
- Enricher is an interface seam; default `NullCostEnricher` is a no-op (offline guarantee).

## 5. Output

- Text: `path(line,col): level RULE: message` + `path: cost score N`.
- SARIF: rules driver, results, `properties.costScores` per artifact.
- JSON: findings array + scores, via AOT source-gen serializer.

## 6. Non-functional

- Cold-start < 1s in CI; no managed runtime needed at run time.
- Deterministic, idempotent formatting. Suppressions are text-based and rule-aware.
- AOT-safe: all (de)serialization via `KqlGuardSarifContext` source generation.

## 7. Risks / mitigations

- Heuristic over-reporting (KQL003/006/008) → tunable weights + suppressions.
- Live cost prediction excluded → deferred behind `ICostEnricher`, no faked dollars.
