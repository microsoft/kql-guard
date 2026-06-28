# kql-guard — Functional Requirements Document (FRD)

## 1. CLI surface

```
kql-guard <path> [--format text|sarif|json] [--max-cost <int>] [--table-sizes <file>]
kql-guard fmt <path> [--write|--check]
```

- `<path>`: a `.kql` file, or a directory scanned recursively for `*.kql`.
- Exit codes: `0` clean · `1` findings or budget breach · `2` usage error.

## 2. Functional requirements

| ID | Requirement |
|----|-------------|
| FR-1 | Parse each file offline via `Kusto.Language`; report parser errors as KQL001. |
| FR-2 | Detect anti-patterns KQL002–KQL010 via AST traversal (Visitor/`GetDescendants`). |
| FR-3 | Each finding has a relative cost weight; file score = sum of weights (errors excluded). |
| FR-4 | `--max-cost n` exits 1 when any file's score > n. |
| FR-5 | `--format sarif` emits SARIF v2.1.0 with rule metadata and per-file cost scores. |
| FR-6 | `--format json` emits a machine-readable findings report. |
| FR-7 | `--table-sizes` loads `{"Table":factor}` and scales scan-rule weights (KQL003/008). |
| FR-8 | Inline comments suppress findings per line / next line / whole file, optionally by rule id. |
| FR-9 | `fmt` formats KQL deterministically and idempotently; `--check` exits 1 if unformatted. |
| FR-10 | Cost rules are skipped for files with syntax errors (unreliable AST). |
| FR-11 | Sentinel `.yaml`/`.yml` rules: extract the embedded `query:` block and lint it, mapping findings to the YAML's own line numbers. |
| FR-12 | `--write-baseline` records findings; `--baseline` suppresses recorded ones (rule+file+message), failing only on new. |

## 3. Rule catalog

| Rule | Flags | Weight |
|------|-------|--------|
| KQL001 | Syntax error | — |
| KQL002 | `contains`/`contains_cs` full-text scan | 1 |
| KQL003 | No time filter — full-table scan | 5 |
| KQL004 | Unscoped `search` | 5 |
| KQL005 | Wildcard `union` | 4 |
| KQL006 | Unwindowed `join` | 3 |
| KQL007 | Regex-heavy (`matches regex`, `extract`, `parse kind=regex`) | 2 |
| KQL008 | No reduction (no `project`/`summarize`/`take`) | 1 |
| KQL009 | Unbounded `mv-expand` | 3 |
| KQL010 | Cross-cluster `cluster()`/`database()` | 2 |
| KQL011 | Unbounded sort (no take/top) | 2 |

## 4. Distribution

- Composite GitHub Action producing SARIF for `upload-sarif`.
- Docker image (NativeAOT binary on `runtime-deps`).
- Binary layerable into super-linter as a custom `*.kql` linter.

## 5. Acceptance

`test/run-tests.sh` exercises every rule, scoring, the budget gate, enrichment,
SARIF validity, and the formatter; all must pass.
