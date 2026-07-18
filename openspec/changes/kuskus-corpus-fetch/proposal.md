## Why

The `kuskus-rule-suggester` change shipped the `QueryCompletion` fetch as a **fail-closed stub**
(`scripts/fetch-corpus.sh`), deferring the real ADX pull to "a separate change" because it needs
confidential-cluster access and managed-identity auth. Everything downstream — calibration, weight
review, shape mining — runs today only against a hand-supplied `--corpus-path`. This change
implements the real fetch so the pipeline can run unattended on the self-hosted runner.

The fetch contract (columns, units, manifest shape, trust boundary, watermark) was pinned and
**verified against the `Azure-Kusto-Service` reference** (`CommandOrQueryLoggingUtils.cs` — the
`$$QUERYCOMPLETION` emitter; `QueryDescription.cs` — `ScannedExtentsStatistics.ScannedRowsCount`;
`managed-identities.md` — the Python managed-identity auth idiom). This change turns that verified
contract into code.

## What Changes

- Add **`scripts/fetch_corpus.py`**: connect to the confidential Kuskus cluster with a **managed
  identity** (`azure-kusto-data`, `with_aad_managed_service_identity_authentication`), pull a
  **watermarked, row-capped, cost-agnostic sliding window** of `QueryCompletion` rows, and write
  `scratch/<id>.kql` (query `Text`) + `manifest.json` (per-id cost) matching the existing contract.
- Keep **`scripts/fetch-corpus.sh`** as the stable entrypoint: `--corpus-path` still short-circuits
  to today's validate-and-passthrough (the offline test seam); otherwise it execs `fetch_corpus.py`.
- **Schema-drift guard**: before pulling, assert the required `QueryCompletion` columns exist
  (`QueryCompletion | getschema`); fail closed printing the live schema if the confidential
  cluster's parsed column names differ from the contract (the KustoLogs→table parser is not in
  source, so this is verified at runtime, once, cheaply).
- **Watermark** persisted in a runner-local state file outside the repo, advanced **only** on a
  fully-successful write, so runs are resumable and gap-free.
- **Boundary preservation**: only the fetched row count reaches stdout; query text lives solely in
  the git-ignored `scratch/`. `Failed` rows are retained (calibration's failure-catch needs them);
  redacted-placeholder, expanded-dialect, and pathologically-large texts are dropped at the source.
- Add `azure-kusto-data` to the **runner** environment only. The NativeAOT binary is untouched;
  `calibrate.py` / `mine.py` remain stdlib-only.

## Capabilities

### New Capabilities
- `corpus-fetch`: Authenticated, watermarked acquisition of confidential `QueryCompletion`
  telemetry into the boundary-side `scratch/` corpus + cost manifest that calibration and mining
  consume — the real replacement for the deferred fetch stub, fail-closed and boundary-preserving.

## Impact

- **Code**: No binary change. One new script (`fetch_corpus.py`) + a wrapper dispatch in the
  existing `fetch-corpus.sh`; one new self-check (`test_fetch_corpus.py`). Wired into
  `test/run-tests.sh`.
- **Dependencies**: `azure-kusto-data` on the runner only (fetch-time). Binary stays NativeAOT,
  offline, source-gen JSON; `calibrate.py`/`mine.py` stay stdlib.
- **Security**: Managed-identity auth (no secrets in repo); confidential cluster targeted because
  query `Text` is Customer Content that exists only on that tier. Only aggregate counts leave the
  fetch to stdout; text stays git-ignored. Every failure path is fail-closed and does not advance
  the watermark.
- **Runner state**: watermark file outside the repo.
- **Deferred still**: the provider-specific AI suggester (unchanged; the mock covers the mining
  path; calibration needs no AI).
