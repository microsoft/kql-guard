# Design — Kuskus corpus-fetch

## Context

The `kuskus-rule-suggester` pipeline consumes a boundary-side corpus: `scratch/<id>.kql` (query
text, git-ignored) + `manifest.json` (per-id cost). Until now that corpus was hand-supplied via
`--corpus-path`; `fetch-corpus.sh` was a fail-closed stub. This change acquires it for real from
the configured Kuskus cluster (starting on the non-confidential `kuskushead`; see Config). The verified
column/unit contract lives in
`../kuskus-rule-suggester/design.md` (Fetch contract) and `scripts/manifest.schema.md`.

## Decisions

**1. Transport: Python `azure-kusto-data`, managed identity.** The reference uses this SDK to query
ADX and write files (`Src/Engine/storage/kraph_cmd/export_snapshot_tables_to_csv.py`); managed
identity is `KustoConnectionStringBuilder.with_aad_managed_service_identity_authentication(cluster)`
(`Doc/data-explorer/managed-identities.md`). The SDK handles auth, paging, and v2 result frames.
It is reflection-based and therefore cannot live in kql-guard's NativeAOT binary — which is exactly
why the fetch is a runner-side script, not binary code. `azure-kusto-data` is added to the runner
only; `calibrate.py`/`mine.py` stay stdlib. Rejected: raw REST + IMDS `curl` (hand-rolled token and
frame parsing, fragile); Kusto CLI (.NET tool, awkward on a Linux runner).

**2. `fetch-corpus.sh` stays the entrypoint.** It dispatches: `--corpus-path <dir> --manifest <f>`
→ the existing validate-and-passthrough (offline test seam, unchanged); otherwise → `exec python3
fetch_corpus.py`. This preserves every caller (`run-calibration.sh`, `run-mining.sh`) and the
offline path with the smallest diff.

**3. Pull scope: sliding contiguous window, cost-agnostic, row-capped.**
```
QueryCompletion
| where Timestamp > todatetime('<watermark>') and Timestamp <= ago(<LAG>)
| where isnotempty(Text) and Text != "[Redacted - see confidential Kuskus for full trace]"
| where strlen(Text) < <MAXLEN>
| top <CAP> by Timestamp asc
| project id = tostring(RequestId), Text,
          durationMs      = totimespan(Duration) / 1ms,
          cpuMs           = todouble(TotalCpuMs),
          memoryPeakBytes = tolong(MemoryPeak),
          scannedRows     = tolong(todynamic(ScannedExtentsStatistics).ScannedRowsCount),
          state = State, failureReason = FailureReason, Timestamp
```
- **Cost-agnostic** (not `top by cost`): calibration needs a representative baseline including
  cheap and failed queries; skewing to expensive rows would corrupt the baseline medians and the
  weight-disagreement signal. Mining does its own cost-ranking downstream.
- `top <CAP> by Timestamp asc` yields a **deterministic oldest-unseen slice**; the watermark then
  advances to the max `Timestamp` pulled → resumable, gap-free, bounded per run; any backlog
  catches up over successive runs. `<LAG>` (≈1h) avoids a partial, still-ingesting tail window.
- One fetch serves both the `calibrate` and `mine` jobs.
- Expanded/internal-dialect rows are dropped runner-side using the shared marker set
  (`manifest.schema.md`); done in Python so there is one authoritative marker list.
- `<CAP>`/`<LAG>`/`<MAXLEN>` and the cluster/db are environment-configurable (see Config).

**4. Opaque id: `RequestId`.** A per-execution `RootActivityId` GUID — unique, content-independent,
OII-safe — is the `<id>`; the row is written to `scratch/<RequestId>.kql`. (The prior design query
selected no id column; this closes that gap.) Ids are never derived from query content.

**5. Schema-drift guard (fail-closed).** The cluster's `QueryCompletion` is produced by
a KustoLogs update policy that is **not in the reference source**, so the parsed column *names* are
inferred from the emitter. Before the first pull the script runs `QueryCompletion | getschema` and
asserts the required column set (`RequestId, Text, Duration, TotalCpuMs, MemoryPeak,
ScannedExtentsStatistics, State, FailureReason, Timestamp`) is present; on mismatch it exits
non-zero and prints the live column list so the operator can reconcile the query. This is the
runtime resolution of the one contract item unverifiable from source.

**6. Watermark.** Runner-local file `${KUSKUS_STATE_DIR}/watermark.txt`, ISO-8601 UTC, outside the
repo. Absent → `read_watermark` returns `None` and `build_query` emits `ago(<BOOTSTRAP>)` (default 7d)
as the lower bound, so the duration stays in KQL (no Python duration parsing). Advanced **only** after
`scratch/` and
`manifest.json` are fully written; on any failure it is left untouched and partial `scratch/`
output is removed, so a rerun re-pulls the same window cleanly. The script stays file-based and pure
(testable); because the runner is **ephemeral** (no persistent disk), the workflow persists this file
to a durable blob around the fetch — see `kuskus-runner-infra` (D6). Fetch is unaware of the storage
backend.

**7. Boundary.** Only the integer row count is printed to stdout. Query text is written solely into
the git-ignored `scratch/`. The manifest carries numbers + `state`/`failureReason` only. `Failed`
rows are retained (calibration's failure-catch consumes their text + reason); `mine.py` already
excludes them itself.

## Data flow

```
fetch-corpus.sh ──(--corpus-path?)──> validate + passthrough        [offline test seam]
        └────────(else)──────────────> fetch_corpus.py
                                          1. connect (MI) → ICslQueryProvider
                                          2. getschema guard (fail-closed)
                                          3. read watermark (or bootstrap)
                                          4. execute windowed KQL
                                          5. for each row: skip dialect markers;
                                             write scratch/<id>.kql = Text;
                                             manifest[id] = {cost, state, failureReason}
                                          6. write manifest.json
                                          7. advance watermark to max(Timestamp)
                                          8. print row count only
```

## Testability

- `fetch_corpus.py` separates the **network call** from a **pure transform**
  `rows_to_corpus(rows) -> (files, manifest)`. `test_fetch_corpus.py` feeds a captured v2 primary
  result-table fixture (small JSON, no live cluster) and asserts: `Text` → `scratch/<id>.kql`;
  unit conversions correct; redacted / dialect-marker / oversized rows skipped; `Failed` rows kept
  (state=="Failed"); `id == RequestId`; no query text on stdout.
- The `--corpus-path` passthrough remains the offline **integration** seam already exercised by the
  e2e script.
- Live-cluster behaviour (auth, getschema, watermark advance) is not unit-tested; it is exercised
  on the runner during the first real dispatch (documented, like the AI path).

## Config (runner env / secrets)

| Var | Meaning | Default |
|-----|---------|---------|
| `KUSKUS_CLUSTER` | cluster URI (non-confidential for now) | `https://kuskushead.westeurope.kusto.windows.net` |
| `KUSKUS_DATABASE` | database | `Kuskus` |
| `KUSKUS_MI_CLIENT_ID` | user-assigned MI client id (unset → system-assigned) | *unset* |
| `KUSKUS_STATE_DIR` | watermark dir (outside repo) | required |
| `KUSKUS_FETCH_CAP` | rows per run | `50000` |
| `KUSKUS_FETCH_LAG` | late-ingestion buffer | `1h` |
| `KUSKUS_FETCH_MAXLEN` | max query text length | `65536` |
| `KUSKUS_FETCH_BOOTSTRAP` | initial lookback when no watermark | `7d` |

The cluster URI is OII (not secret) so a default is fine; it stays overridable. For local
developer testing against a dev cluster, `with_az_cli_authentication` may be substituted behind an
env flag — the runner path always uses managed identity.

Starting on the non-confidential `kuskushead`, query `Text` is mostly the redacted placeholder, so
the corpus is **calibration-first** (cost columns are unredacted regardless of tier); flip
`KUSKUS_CLUSTER` to `kuskusheadconf` when confidential access is granted to unstarve mining.
