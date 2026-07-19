#!/usr/bin/env python3
"""Self-checks for fetch_corpus.py. No framework: assert + exit code.

Runs offline — fetch_corpus lazy-imports the Kusto SDK inside connect(), so the
module imports and every pure function is testable without azure-kusto-data.
The live cluster path (connect/execute) is exercised on the runner, not here.
"""
import os
import shutil
import sys
import tempfile

import fetch_corpus as fc

REDACTED = fc.REDACTED_PLACEHOLDER


def check(label, cond):
    print(("ok" if cond else "FAIL") + ": " + label)
    return 0 if cond else 1


# A window: a good Completed row, a Failed row (KEEP), a redacted row (skip),
# a dialect-expanded row (skip), an over-maxlen row (skip). The two skipped-by-
# content rows carry the newest timestamps so we can prove the watermark still
# advances past rows that never reach the corpus (else an all-redacted window
# on the non-confidential cluster would loop forever).
ROWS = [
    {"id": "aaa", "Text": "SecurityEvent | take 5",
     "durationMs": 12.5, "cpuMs": 6.0, "memoryPeakBytes": 2000, "scannedRows": 100,
     "state": "Completed", "failureReason": None, "Timestamp": "2026-07-19T10:00:00Z"},
    {"id": "bbb", "Text": "BadTable | where x == 1",
     "durationMs": 3.0, "cpuMs": 1.0, "memoryPeakBytes": 500, "scannedRows": 0,
     "state": "Failed", "failureReason": "SEM0100: unresolved", "Timestamp": "2026-07-19T10:01:00Z"},
    {"id": "ccc", "Text": REDACTED,
     "durationMs": 9.0, "cpuMs": 4.0, "memoryPeakBytes": 800, "scannedRows": 10,
     "state": "Completed", "failureReason": None, "Timestamp": "2026-07-19T10:05:00Z"},
    {"id": "ddd", "Text": "T | where __invoke(foo)",
     "durationMs": 9.0, "cpuMs": 4.0, "memoryPeakBytes": 800, "scannedRows": 10,
     "state": "Completed", "failureReason": None, "Timestamp": "2026-07-19T10:06:00Z"},
    {"id": "eee", "Text": "T | " + "x" * fc.DEFAULT_MAXLEN,
     "durationMs": 9.0, "cpuMs": 4.0, "memoryPeakBytes": 800, "scannedRows": 10,
     "state": "Completed", "failureReason": None, "Timestamp": "2026-07-19T10:07:00Z"},
]


class FakeResp:
    def __init__(self, rows):
        self.primary_results = [rows]


class FakeClient:
    """Stands in for KustoClient: getschema returns column names; the data query
    returns ROWS (or raises, to exercise fail-closed)."""
    def __init__(self, cols, data_rows, raise_on_data=False):
        self.cols = cols
        self.data_rows = data_rows
        self.raise_on_data = raise_on_data

    def execute(self, db, query):
        if "getschema" in query:
            return FakeResp([{"ColumnName": c} for c in self.cols])
        if self.raise_on_data:
            raise RuntimeError("boom")
        return FakeResp(self.data_rows)


def test_rows_to_corpus(fails):
    d = tempfile.mkdtemp()
    try:
        manifest, max_ts = fc.rows_to_corpus(ROWS, d)
        # Good + Failed rows written; redacted/dialect/oversized skipped.
        fails += check("good row written", os.path.exists(os.path.join(d, "aaa.kql")))
        fails += check("failed row KEPT", os.path.exists(os.path.join(d, "bbb.kql")))
        fails += check("redacted row skipped", not os.path.exists(os.path.join(d, "ccc.kql")))
        fails += check("dialect row skipped", not os.path.exists(os.path.join(d, "ddd.kql")))
        fails += check("oversized row skipped", not os.path.exists(os.path.join(d, "eee.kql")))
        with open(os.path.join(d, "aaa.kql")) as f:
            fails += check("scratch/<id>.kql == Text", f.read() == "SecurityEvent | take 5")
        # Manifest: cost-only, no text, no timestamp; id == RequestId (row id).
        fails += check("manifest has 2 entries", set(manifest) == {"aaa", "bbb"})
        fails += check("manifest entry cost-only", manifest["aaa"] == {
            "durationMs": 12.5, "cpuMs": 6.0, "memoryPeakBytes": 2000,
            "scannedRows": 100, "state": "Completed", "failureReason": None})
        fails += check("no Text in manifest", all("Text" not in e for e in manifest.values()))
        fails += check("no Timestamp in manifest", all("Timestamp" not in e for e in manifest.values()))
        fails += check("failure reason kept for Failed row",
                       manifest["bbb"]["failureReason"] == "SEM0100: unresolved")
        # Watermark advances past ALL pulled rows, including skipped ones.
        fails += check("max_ts is newest of ALL rows", max_ts == "2026-07-19T10:07:00Z")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return fails


def test_all_skipped_still_advances(fails):
    """An all-redacted window (realistic on the non-confidential cluster) writes
    nothing but MUST still advance the watermark, or the pipeline never progresses."""
    d = tempfile.mkdtemp()
    try:
        rows = [{"id": "z", "Text": REDACTED, "durationMs": 1.0, "cpuMs": 1.0,
                 "memoryPeakBytes": 1, "scannedRows": 1, "state": "Completed",
                 "failureReason": None, "Timestamp": "2026-07-19T11:00:00Z"}]
        manifest, max_ts = fc.rows_to_corpus(rows, d)
        fails += check("empty corpus", manifest == {})
        fails += check("watermark still advances", max_ts == "2026-07-19T11:00:00Z")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return fails


def test_watermark(fails):
    d = tempfile.mkdtemp()
    try:
        fails += check("absent watermark -> None", fc.read_watermark(d) is None)
        fc.advance_watermark(d, "2026-07-19T10:07:00Z")
        fails += check("watermark round-trips", fc.read_watermark(d) == "2026-07-19T10:07:00Z")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return fails


def test_assert_schema(fails):
    full = FakeClient(fc.REQUIRED_COLUMNS, ROWS)
    try:
        fc.assert_schema(full, "Kuskus")
        fails += check("full schema passes", True)
    except Exception:
        fails += check("full schema passes", False)
    truncated = FakeClient(fc.REQUIRED_COLUMNS - {"TotalCpuMs"}, ROWS)
    try:
        fc.assert_schema(truncated, "Kuskus")
        fails += check("missing column raises", False)
    except Exception as e:
        fails += check("missing column raises", "TotalCpuMs" in str(e))
    return fails


def test_build_query(fails):
    q = fc.build_query("2026-07-19T00:00:00Z", 50000, "1h", 65536, "7d")
    fails += check("query carries watermark", "2026-07-19T00:00:00Z" in q)
    fails += check("query is oldest-first capped", "top 50000 by Timestamp asc" in q)
    fails += check("query filters redacted", REDACTED in q)
    fails += check("query converts duration", "totimespan(Duration) / 1ms" in q)
    fails += check("query reads scanned rows", "ScannedExtentsStatistics" in q)
    boot = fc.build_query(None, 10, "1h", 100, "7d")
    fails += check("no watermark bootstraps", "ago(7d)" in boot)
    return fails


def _run_main(client, state_dir):
    """main() writes to CWD; run it in a throwaway dir."""
    cwd = os.getcwd()
    work = tempfile.mkdtemp()
    os.chdir(work)
    os.environ["KUSKUS_STATE_DIR"] = state_dir
    try:
        rc = fc.main([], client=client)
        return rc, work
    finally:
        os.chdir(cwd)


def test_main_success(fails):
    state = tempfile.mkdtemp()
    client = FakeClient(fc.REQUIRED_COLUMNS, ROWS)
    rc, work = _run_main(client, state)
    try:
        fails += check("main returns 0", rc == 0)
        fails += check("scratch written", os.path.exists(os.path.join(work, "scratch", "aaa.kql")))
        fails += check("manifest written", os.path.exists(os.path.join(work, "manifest.json")))
        fails += check("watermark advanced", fc.read_watermark(state) == "2026-07-19T10:07:00Z")
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)
    return fails


def test_main_fail_closed(fails):
    """Query raises -> exit 1, watermark untouched, no partial output."""
    state = tempfile.mkdtemp()
    fc.advance_watermark(state, "2026-07-19T09:00:00Z")  # a prior run's mark
    client = FakeClient(fc.REQUIRED_COLUMNS, ROWS, raise_on_data=True)
    rc, work = _run_main(client, state)
    try:
        fails += check("failed fetch returns nonzero", rc != 0)
        fails += check("watermark untouched", fc.read_watermark(state) == "2026-07-19T09:00:00Z")
        fails += check("no partial scratch", not os.path.exists(os.path.join(work, "scratch")))
        fails += check("no partial manifest", not os.path.exists(os.path.join(work, "manifest.json")))
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)
    return fails


def main():
    fails = 0
    fails = test_rows_to_corpus(fails)
    fails = test_all_skipped_still_advances(fails)
    fails = test_watermark(fails)
    fails = test_assert_schema(fails)
    fails = test_build_query(fails)
    fails = test_main_success(fails)
    fails = test_main_fail_closed(fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
