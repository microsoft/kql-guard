## ADDED Requirements

### Requirement: Authenticated windowed corpus fetch

The fetch step SHALL, when no local corpus is supplied, connect to the confidential Kuskus cluster
using a **managed identity** and pull `QueryCompletion` rows into `scratch/<id>.kql` (query `Text`)
and a per-`<id>` cost `manifest.json` (`durationMs`, `cpuMs`, `memoryPeakBytes`, `scannedRows`,
`state`, `failureReason`), matching the existing manifest contract. It SHALL target the confidential
tier (where query text exists), read cluster/database/limits from the runner environment, and use a
per-execution activity id (`RequestId`) as `<id>` — never an id derived from query content. The pull
SHALL be bounded to a deterministic sliding window: rows with `Timestamp` after the watermark and
before a late-ingestion lag, capped to a configurable row count taken oldest-first, and SHALL NOT
rank or filter by cost (so calibration's baseline is representative). It SHALL drop the redacted
placeholder, expanded/internal-dialect rows, and rows whose text exceeds a configured maximum. It
SHALL retain `state == "Failed"` rows (calibration's failure-catch consumes them).

#### Scenario: Rows become scratch files and a cost manifest

- **WHEN** the fetch pulls a `QueryCompletion` row with text T and cost fields
- **THEN** `scratch/<RequestId>.kql` contains T and `manifest["<RequestId>"]` contains the cost
  numbers plus `state`/`failureReason`, and contains no query text

#### Scenario: The window is cost-agnostic and bounded

- **WHEN** more than the configured cap of new rows exist since the watermark
- **THEN** exactly the oldest-first cap of rows (by `Timestamp`) is pulled, regardless of their cost

#### Scenario: Excluded rows are dropped, failed rows kept

- **WHEN** the source contains a redacted-placeholder row, an expanded-dialect row, an
  over-maximum-length row, and a `state == "Failed"` row
- **THEN** the first three are absent from `scratch/` and the manifest, and the `Failed` row is
  present (retained for calibration)

### Requirement: Schema-drift guard

Before pulling data, the fetch SHALL verify that the live `QueryCompletion` table exposes the
columns the query depends on, and SHALL fail closed — exiting non-zero and reporting the live column
list — if any required column is missing. This verifies at runtime the parsed column names that are
not available in source.

#### Scenario: Missing column aborts the fetch

- **WHEN** the live `QueryCompletion` schema is missing a required column
- **THEN** the fetch exits non-zero, reports the actual columns, and pulls no data

### Requirement: Resumable watermark, fail-closed

The fetch SHALL persist a watermark in a runner-local location outside the repository and SHALL
advance it to the maximum `Timestamp` pulled **only** after the scratch corpus and manifest are
fully written. On any failure it SHALL leave the watermark unchanged and remove partial scratch
output, so a rerun re-pulls the same window without gaps or duplication. When no watermark exists it
SHALL start from a configured bootstrap lookback.

#### Scenario: Successful run advances the watermark

- **WHEN** a fetch completes and writes N rows whose maximum `Timestamp` is M
- **THEN** the watermark file is updated to M

#### Scenario: Failed run does not advance the watermark

- **WHEN** a fetch fails after partially writing scratch output
- **THEN** the watermark is unchanged and the partial scratch output is removed

### Requirement: Boundary preservation and offline seam

The fetch SHALL emit only the fetched row count to standard output; query text SHALL exist only in
the git-ignored `scratch/` directory and never in logs. The entrypoint SHALL retain a local-corpus
mode (`--corpus-path`) that validates and passes through a pre-materialized corpus without contacting
any cluster, and the row-to-corpus transform SHALL be exercisable by a self-check without a live
cluster.

#### Scenario: No query text reaches stdout

- **WHEN** the fetch runs
- **THEN** its standard output contains only an aggregate row count, no query text

#### Scenario: Offline corpus path needs no cluster

- **WHEN** the entrypoint is invoked with `--corpus-path <dir> --manifest <file>`
- **THEN** it validates and uses that corpus without connecting to any cluster
