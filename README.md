# kql-guard

A fast, **offline** static analyzer for Kusto Query Language (KQL). Built for
"Detection as Code" pipelines (Microsoft Sentinel, Azure Data Explorer), it
catches syntax errors and **financially dangerous query shapes** in CI — before
a costly query is ever merged.

- **No database connection, no Azure auth, no network.** Parses the query AST
  offline using the official `Kusto.Language` API.
- **NativeAOT single binary** — instant startup in ephemeral CI runners.
- **SARIF v2.1.0 output** — annotates GitHub / Azure DevOps pull requests as
  code-scanning alerts.

## Usage

```bash
kql-guard <path> [--format text|sarif|json] [--max-cost <int>] [--table-sizes sizes.json]
```

| Argument | Description |
|----------|-------------|
| `<path>` | A `.kql` file or a directory scanned recursively for `*.kql`. |
| `--format text\|sarif\|json` | Output as text diagnostics (default), SARIF v2.1.0, or JSON. |
| `--max-cost <n>` | Fail (exit `1`) if any file's cost score exceeds `n`. |
| `--table-sizes <file>` | Offline JSON map `{"Table":factor}` scaling scan-rule weights per table. |

Exit codes: `0` clean · `1` findings or budget breach · `2` usage error.

**Suppress** a finding with an inline comment: `// kql-guard:disable KQL003`,
`// kql-guard:disable-next-line` or `// kql-guard:disable-file`.

### Example

```text
$ kql-guard detections/
detections/suspicious.kql(2,1): warning KQL003: No time filter; add e.g. '| where TimeGenerated > ago(1d)' ...
detections/suspicious.kql: cost score 5
```

## Rules

Every finding carries a relative, unitless **cost weight**. A file's **cost
score** is the sum of its findings' weights (syntax errors don't count). The
score is intentionally not a dollar figure — that can't be computed honestly
offline.

| Rule | What it flags | Weight |
|------|---------------|--------|
| KQL001 | Syntax error (from the parser) | — |
| KQL002 | `contains` / `contains_cs` — full-text scan; prefer `has` | 1 |
| KQL003 | Table query with **no time filter** (`ago()`/`between`) — full-table scan | 5 |
| KQL004 | **Unscoped `search`** — queries every table | 5 |
| KQL005 | **Wildcard `union`** (`union *`, `union T*`) — fans out across tables | 4 |
| KQL006 | **Unwindowed `join`** — no time filter before joining | 3 |
| KQL007 | **Regex-heavy** (`matches regex`, `extract`/`extract_all`, `parse kind=regex`) | 2 |
| KQL008 | **No reduction** (no `project`/`summarize`/`take`) — keeps all columns/rows | 1 |
| KQL009 | **Unbounded `mv-expand`** — no `limit`, can explode row counts | 3 |
| KQL010 | **Cross-cluster** `cluster()`/`database()` — network egress, latency | 2 |

KQL003, KQL006 and KQL008 are heuristics and may occasionally over-report;
their weights are all defined in one place (`Rules.All` in
[`CostRules.cs`](CostRules.cs)) so they can be tuned in one edit. Cost rules are
skipped for files that have syntax errors (the AST is unreliable until those
are fixed).

## Formatter

Deterministic, idempotent KQL formatting (gofmt/Prettier-style), delegating to
the official `Kusto.Language` formatter — canonical one-pipe-per-line layout.

```bash
kql-guard fmt <path>            # print formatted KQL to stdout
kql-guard fmt <path> --write    # rewrite files in place
kql-guard fmt <path> --check    # exit 1 if any file isn't formatted (CI gate)
```

## GitHub Action

```yaml
- uses: microsoft/kql-guard@v1
  with:
    path: "."
```

The composite action runs the scan and produces `kql-guard-results.sarif` for
`github/codeql-action/upload-sarif`. See [`action.yml`](action.yml).

## Container & super-linter

A self-contained image ships only the NativeAOT binary:

```bash
docker build -t kql-guard .
docker run --rm -v "$PWD:/work" kql-guard /work/detections
```

The same binary layers into [`super-linter`](https://github.com/super-linter/super-linter):
copy `/usr/local/bin/kql-guard` into the super-linter image and register `*.kql`
as a custom linter step — no .NET runtime required.

## Build & test

```bash
dotnet publish -c Release -r linux-x64   # NativeAOT binary
./test/run-tests.sh                      # rule self-check (no framework)
```

## Roadmap

- **Live-API cost enrichment** — `--table-sizes` already scales weights from a
  static map; a future opt-in step fetches real sizes via the `ICostEnricher`
  seam, keeping the default fully offline.
- **Upstream into `super-linter`** for out-of-the-box KQL validation.
