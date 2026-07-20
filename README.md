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
kql-guard <path> [--format text|sarif|json] [--max-cost <int>] [--strict] [--table-sizes sizes.json] [--baseline file] [--write-baseline] [--schema schemas.json]
```

| Argument | Description |
|----------|-------------|
| `<path>` | A `.kql`/`.yaml`/`.yml` file or a directory scanned recursively. Sentinel `.yaml` rules: the embedded `query:` is linted in place. |
| `--format text\|sarif\|json` | Output as text diagnostics (default), SARIF v2.1.0, or JSON. |
| `--shapes` | Internal (shape mining): with `--format json`, add a per-query boundary-safe AST **shape signature** map — operator/built-in kinds only, no identifiers or literals. Not needed for routine linting; see Roadmap. |
| `--max-cost <n>` | Fail (exit `1`) if any file's cost score exceeds `n`. |
| `--strict` | Fail (exit `1`) on any finding, including advisory cost warnings. |
| `--table-sizes <file>` | Offline JSON map `{"Table":factor}` scaling scan-rule weights per table. |
| `--baseline <file>` | Suppress findings recorded in the baseline; fail only on new ones. |
| `--write-baseline` | Record current findings to the baseline and exit 0. |
| `--schema <file>` | Opt-in semantic check: bind table schemas (`{"Table":[{"name","type"}]}`) and flag unknown columns/tables as `KQL101`. Object-form files (`{"tables":{…},"functions":[…]}`, as written by `pull`) additionally bind stored functions so their calls resolve. |

Exit codes: `0` clean or advisory-only · `1` errors (`KQL001`/`KQL101`), `--max-cost` breach, or any finding under `--strict` · `2` usage error.

Cost warnings (`KQL002`–`KQL013`) are **advisory** — a valid-but-expensive query reports its cost score but exits `0` on its own. Gate on cost with `--max-cost`, or fail on every finding with `--strict`. Only real errors (syntax/schema) fail by default.

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
| KQL101 | Unknown column/table/function — **requires** `--schema` | — |
| KQL002 | `contains` / `contains_cs` — full-text scan; prefer `has` | 1 |
| KQL003 | Table query with **no time filter** (`ago()`/`between`) — full-table scan | 5 |
| KQL004 | **Unscoped `search`** — queries every table | 5 |
| KQL005 | **Wildcard `union`** (`union *`, `union T*`) — fans out across tables | 4 |
| KQL006 | **Unwindowed `join`** — no time filter before joining | 3 |
| KQL007 | **Regex-heavy** (`matches regex`, `extract`/`extract_all`, `parse kind=regex`) | 2 |
| KQL008 | **No reduction** (no `project`/`summarize`/`take`) — keeps all columns/rows | 1 |
| KQL009 | **Unbounded `mv-expand`** — no `limit`, can explode row counts | 3 |
| KQL010 | **Cross-cluster** `cluster()`/`database()` — network egress, latency | 2 |
| KQL011 | **Unbounded `sort`/`order by`** — full sort, no `take`/`top` | 2 |
| KQL012 | **Case-fold equality** `tolower()==` — defeats index; use `=~` | 2 |
| KQL013 | **Non-deterministic `take`** — no `sort`/`top` | 1 |

KQL003, KQL006 and KQL008 are heuristics and may occasionally over-report;
their weights are all defined in one place (`Rules.All` in
[`CostRules.cs`](CostRules.cs)) so they can be tuned in one edit. Cost rules are
skipped for files that have syntax errors (the AST is unreliable until those
are fixed).

> Rule priorities are validated against real usage: over a 7-day window of
> ~425K Kusto queries, ~72% lacked a time filter (KQL003), 18% had unbounded
> sorts (KQL011), 15% mv-expand/cross-cluster (KQL009/010), and ~2K used
> index-defeating `tolower()==` (KQL012).

## Formatter

Deterministic, idempotent KQL formatting (gofmt/Prettier-style), delegating to
the official `Kusto.Language` formatter — canonical one-pipe-per-line layout.

```bash
kql-guard fmt <path>            # print formatted KQL to stdout
kql-guard fmt <path> --write    # rewrite files in place
kql-guard fmt <path> --check    # exit 1 if any file isn't formatted (CI gate)
```

## Live schema pull

`lint` stays **100% offline** — but a real cluster knows things a checked-in
schema doesn't: every table's columns, the stored **functions** your queries
call, and how big each table actually is. The opt-in `pull` subcommand fetches
those over the Kusto REST API and writes them into the very same `--schema` /
`--table-sizes` files the offline linter already consumes. Pull once, commit the
result, then lint offline forever.

```bash
# 1. Fetch schema (tables + stored functions) into a --schema file.
kql-guard pull --cluster https://help.kusto.windows.net --database Samples -o schemas.json

# 2. (optional) Also fetch per-table sizes into a --table-sizes map.
kql-guard pull --cluster https://help.kusto.windows.net --database Samples \
  -o schemas.json --with-sizes sizes.json

# 3. Commit schemas.json / sizes.json, then lint offline — function calls now bind.
kql-guard detections/ --schema schemas.json --table-sizes sizes.json
```

| Flag | Description |
|------|-------------|
| `--cluster <uri>` | Cluster URI, e.g. `https://help.kusto.windows.net`. |
| `--database <db>` | Database to pull (one per invocation). |
| `-o, --out <file>` | Schema output path (default `schemas.json`). |
| `--with-sizes <file>` | Also fetch `.show tables details` and write a `{"Table":factor}` size map. |
| `--size-baseline <bytes>` | Bytes that equal factor `1`; defaults to the median table size. |
| `--token <jwt>` | Bearer token; or set `KQL_GUARD_TOKEN`. **Never logged.** |

**Auth is an injected bearer token only** — no SDK, no interactive sign-in, so
the single NativeAOT binary is preserved. In CI:

```bash
export KQL_GUARD_TOKEN=$(az account get-access-token --resource https://help.kusto.windows.net --query accessToken -o tsv)
kql-guard pull --cluster https://help.kusto.windows.net --database Samples -o schemas.json
```

Schema needs only `Database Viewer`; `--with-sizes` additionally needs
`Database Monitor` (hence it stays opt-in). Exit codes: `0` success · `1` a
request failed · `2` usage error (e.g. missing token).

## GitHub Action

```yaml
- uses: microsoft/kql-guard@v1
  with:
    path: detections          # file or dir to scan (default ".")
- uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: kql-guard-results.sarif
```

The action installs the binary itself — no build step needed. Pick how via `mode`:

| `mode` | What it does |
|--------|--------------|
| `download` *(default)* | Fetches the release asset for the runner (linux-x64/arm64, osx-arm64, win-x64). |
| `docker` | Runs `ghcr.io/microsoft/kql-guard:<version>`. Use for runners without a release asset. |
| `prebuilt` | Runs a locally-built binary (`bin/Release/...` or `prebuilt-path`). |

**Inputs:** `mode`, `version` (release/image tag, default `latest`), `path`, `format`
(`sarif`/`text`/`json`), `max-cost`, `schema`, `args` (raw passthrough),
`working-directory`, `fail-on-violations` (default `false`), `prebuilt-path`.

**Outputs:** `sarif-file`, `exit-code` (0 clean/advisory · 1 errors, `--max-cost` breach, or `--strict` findings · 2 usage).

By default the action stays green and surfaces findings via `exit-code`; set
`fail-on-violations: true` to fail the job when `exit-code` is 1. Cost warnings
are advisory — gate on them by passing `--max-cost N` or `--strict` via `args`.
See [`action.yml`](action.yml).

## Azure DevOps

Same analyzer, packaged as an Azure Pipelines task. Install the extension
(`azure-devops/`), then:

```yaml
- task: KqlGuard@1
  inputs:
    path: 'detections'          # file or dir to scan (default ".")
```

The task installs the binary itself (same three `mode`s as the Action:
`download` *(default)* / `docker` / `prebuilt`) and, for `format: sarif`,
surfaces findings two ways: it publishes the SARIF as a **`CodeAnalysisLogs`**
artifact (rendered by the free
[SARIF SAST Scans Tab](https://marketplace.visualstudio.com/items?itemName=sariftools.scans)
extension) **and** logs each finding inline as a build warning/error.

**Inputs:** `path`, `mode`, `version` (default `latest`), `format`, `maxCost`,
`schema`, `args` (raw passthrough), `workingDirectory`, `failOnViolations`
(default `false`), `prebuiltPath`, plus `publishSarifArtifact`/`logIssues` (both
default `true`). **Outputs:** `exitCode`, `sarifFile`.

```yaml
# Gate the pipeline on errors or a cost budget:
- task: KqlGuard@1
  inputs:
    path: 'detections'
    maxCost: '50'
    failOnViolations: true
```

Advisory by default (the stage stays green, `exitCode` is set); set
`failOnViolations: true` to fail on exit 1. See [`azure-devops/`](azure-devops/).

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

- **Rule calibration (internal)** — an aperiodic pipeline
  (`.github/workflows/kuskus-report.yml`, self-hosted Kuskus-access runner)
  correlates kql-guard findings with real ADX `QueryCompletion` execution cost
  to validate rule CostWeights and surface weight-review PRs. It runs entirely
  boundary-side (`scripts/*.py`, `scripts/*.sh`) and enforces a strict trust
  boundary: confidential query text stays in the git-ignored `scratch/`, and
  only aggregate numbers + rule IDs ever cross into this repo (guarded by
  `scripts/leak-guard.sh`). Weight changes are mechanical and human-reviewed;
  no query text or AI is involved on that path. See
  `openspec/changes/kuskus-rule-suggester/` for the full design.

- **Shape mining (internal).** An aperiodic, self-hosted pipeline clusters
  recurring query shapes (`--shapes`) from internal telemetry and drafts
  human-reviewed new-rule PRs behind the same strict trust boundary. Only
  abstracted shape signatures + aggregate cost cross into this repo; drafted
  rules are synthetic, fail-closed validated (`scripts/validate-candidate.sh`),
  and never used by public lint-in-CI runs.
- **Live-API cost enrichment** — `--table-sizes` scales weights from a static
  map; `pull --with-sizes` fetches real sizes into that map via the
  `ICostEnricher` seam, keeping the default fully offline.
- **Upstream into `super-linter`** for out-of-the-box KQL validation.
