## 1. Runner dependency + wrapper dispatch

- [x] 1.1 Document `azure-kusto-data` as a runner-only dependency (README/runner setup notes); it is NOT added to the binary or to `calibrate.py`/`mine.py`. Pin a version.
- [x] 1.2 In `scripts/fetch-corpus.sh`, keep the `--corpus-path`/`--manifest` branch exactly as today (validate + passthrough = offline test seam). When `--corpus-path` is absent, `exec python3 "$(dirname "$0")/fetch_corpus.py" "$@"` instead of the "not implemented" exit. Preserve `set -euo pipefail`.
- [x] 1.3 Self-check: `fetch-corpus.sh --corpus-path <fixture> --manifest <f>` still passes through unchanged (existing behavior, no regression).

## 2. Pure transform `rows_to_corpus` (TDD; the boundary-critical logic)

- [x] 2.1 Write `scripts/test_fetch_corpus.py` first: a captured v2 primary-result fixture (list of row dicts with `id, Text, durationMs, cpuMs, memoryPeakBytes, scannedRows, state, failureReason, Timestamp`) → assert `rows_to_corpus(rows, scratch_dir)` writes `scratch/<id>.kql == Text`, returns `manifest[id] == {durationMs, cpuMs, memoryPeakBytes, scannedRows, state, failureReason}` (no `Text`, no `Timestamp`), and returns the max Timestamp seen.
- [x] 2.2 Assert row filtering: a redacted-placeholder row, an expanded-dialect row (shared marker list from `manifest.schema.md`), and an over-`MAXLEN` row are all skipped; a `state=="Failed"` row is **kept** (calibration needs it).
- [x] 2.3 Assert the boundary: `id` equals the row's `RootActivityId`/`id` (content-independent); no query text is returned in the manifest or printed.
- [x] 2.4 Run the tests → fail (`rows_to_corpus` undefined).
- [x] 2.5 Implement `rows_to_corpus(rows, scratch_dir)` in `scripts/fetch_corpus.py`: pure function, no network; write files + build manifest + track max Timestamp; apply the skip filters. Run tests → pass.

## 3. Watermark read/advance (TDD)

- [x] 3.1 Test first: `read_watermark(state_dir)` returns the file contents when present, else `now - BOOTSTRAP`; `advance_watermark(state_dir, ts)` writes `ts`; a round-trip preserves the value. Use a temp dir.
- [x] 3.2 Run → fail. Implement both (plain file I/O, ISO-8601 UTC). Run → pass.
- [x] 3.3 Assert fail-closed ordering in code review: `advance_watermark` is called only after `manifest.json` is fully written; on exception, partial `scratch/` is cleaned and the watermark is untouched (covered by a test that raises mid-write and asserts the watermark file is unchanged).

## 4. Schema-drift guard

- [x] 4.1 Implement `assert_schema(client, db)`: run `QueryCompletion | getschema | project ColumnName`, require the set `{RootActivityId, Text, Duration, TotalCPU, MemoryPeak, ScannedExtentsStatistics, State, FailureReason, Timestamp}` ⊆ live columns; on mismatch raise with the live column list in the message (fail-closed). ponytail: names inferred from the emitter — this is the runtime verification.
- [x] 4.2 Test with a fake client returning a truncated column set → raises; full set → passes. No live cluster.

## 5. Connection + windowed query (managed identity)

- [x] 5.1 Implement `connect()`: build `KustoConnectionStringBuilder.with_aad_managed_service_identity_authentication(KUSKUS_CLUSTER, client_id=KUSKUS_MI_CLIENT_ID or None)` → `KustoClient`. Read cluster/db/knobs from env (see design Config table) with the documented defaults.
- [x] 5.2 Implement `build_query(watermark, cap, lag, maxlen, bootstrap, bytes_cap)` returning the design KQL (parameterize watermark/cap/lag/maxlen/bytes; server-side unit conversions). Unit-test that the emitted KQL contains the watermark, `order by Timestamp asc` + the `row_cumsum` byte budget + `take <cap>`, the redaction filter, and the unit conversions (string assertions, no cluster).
- [x] 5.3 Implement `main()`: connect → `assert_schema` → `read_watermark` → execute query → `rows_to_corpus` → write `manifest.json` → `advance_watermark(max_ts)` → print only the row count. `sys.exit(1)` (non-zero) on any failure, watermark untouched.

## 6. Unstub the pipeline wiring

- [x] 6.1 `.github/workflows/kuskus-report.yml`: the `fetch-corpus.sh` step performs the real pull on the runner (no `--corpus-path`); pass `KUSKUS_*` via env/secrets. `workflow_dispatch` keeps an optional `corpus_path` input to force the offline seam. Update the deferred-integrations header note to drop the fetch (AI suggester remains deferred). Note: `kuskus-runner-infra` merges `calibrate`+`mine` into one job and adds the durable-watermark blob sync — coordinate so the workflow is edited once.
- [x] 6.2 Confirm `run-calibration.sh` / `run-mining.sh` need no change (they already call `fetch-corpus.sh` and consume `scratch/` + `manifest.json`).

## 7. Docs + verification

- [x] 7.1 Update `scripts/manifest.schema.md` / `../kuskus-rule-suggester/design.md` cross-reference if the id column (`RootActivityId`) or the cluster default needs mentioning (id was previously unspecified).
- [x] 7.2 `./test/run-tests.sh` wires `test_fetch_corpus.py`; full fast suite passes; `scripts/e2e-mining.sh` still green via the `--corpus-path` seam (no live cluster needed).
- [x] 7.3 `openspec validate kuskus-corpus-fetch --strict` passes.
- [ ] 7.4 Manual runner smoke (documented, not in CI): first dispatch performs `getschema` guard, pulls a bounded window, advances the watermark, and the calibrate/mine jobs produce their reports with no query text in any log.
