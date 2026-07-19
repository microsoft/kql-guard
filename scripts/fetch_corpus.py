#!/usr/bin/env python3
"""Pull a QueryCompletion corpus from Kuskus ADX into scratch/<id>.kql + manifest.json.

Runs on the self-hosted runner (see openspec/changes/kuskus-corpus-fetch). The
Kusto SDK is reflection-based and cannot live in kql-guard's NativeAOT binary, so
the fetch is a runner-side script; azure-kusto-data is a runner-only dependency.

The SDK is imported lazily inside connect() so this module — and every pure
function below — imports and tests without the dependency present (CI has no SDK).
Only aggregate row counts reach stdout; query text lives solely in the
git-ignored scratch/. Every failure path is fail-closed: partial output is
removed and the watermark is left untouched, so a rerun re-pulls the same window.
"""
import json
import os
import shutil
import sys

DEFAULT_CLUSTER = "https://kuskushead.westeurope.kusto.windows.net"
DEFAULT_MAXLEN = 65536
REDACTED_PLACEHOLDER = "[Redacted - see confidential Kuskus for full trace]"

# Columns the query depends on; verified live at startup (assert_schema) because
# the KustoLogs->QueryCompletion parser is not in the reference source.
REQUIRED_COLUMNS = {"RequestId", "Text", "Duration", "TotalCpuMs", "MemoryPeak",
                    "ScannedExtentsStatistics", "State", "FailureReason", "Timestamp"}

# Engine-expanded / internal-dialect forms are machine rewrites, not user-authored
# KQL, so they are noise for rule-learning and dropped runner-side (one authoritative
# list; manifest.schema.md documents the contract).
# ponytail: '["' also matches legitimate bag/dynamic indexing (over-broad); calibration-
# first on the non-confidential cluster makes the recall loss negligible for now — tighten
# to the specific expanded column-ref form if mining on confidential needs those queries.
DIALECT_MARKERS = ("__invoke(", '["', "assert-schema", "$matchesregex")

_MANIFEST_KEYS = ("durationMs", "cpuMs", "memoryPeakBytes", "scannedRows", "state", "failureReason")
_ROW_KEYS = ("id", "Text") + _MANIFEST_KEYS + ("Timestamp",)


def rows_to_corpus(rows, scratch_dir, maxlen=DEFAULT_MAXLEN):
    """Pure transform (no network): write scratch/<id>.kql for each retained row
    and build the per-id cost manifest. Returns (manifest, max_timestamp).

    Skips empty/redacted/dialect-expanded/oversized text; KEEPS Failed rows
    (calibration's failure-catch needs their text + reason). The watermark
    advances past EVERY pulled row, retained or skipped, so an all-redacted
    window still makes forward progress instead of looping.
    """
    os.makedirs(scratch_dir, exist_ok=True)
    manifest = {}
    max_ts = None
    for r in rows:
        ts = r.get("Timestamp")
        if ts is not None and (max_ts is None or ts > max_ts):
            max_ts = ts
        text = r.get("Text")
        if not text or text == REDACTED_PLACEHOLDER or len(text) >= maxlen:
            continue
        if any(m in text for m in DIALECT_MARKERS):
            continue
        qid = r["id"]
        with open(os.path.join(scratch_dir, qid + ".kql"), "w") as f:
            f.write(text)
        manifest[qid] = {k: r.get(k) for k in _MANIFEST_KEYS}
    return manifest, max_ts


def read_watermark(state_dir):
    """Return the persisted watermark, or None to bootstrap (query uses ago(BOOTSTRAP))."""
    path = os.path.join(state_dir, "watermark.txt")
    if os.path.exists(path):
        with open(path) as f:
            return f.read().strip()
    return None


def advance_watermark(state_dir, ts):
    """Persist the watermark (ISO-8601). Called only after a fully-written corpus."""
    os.makedirs(state_dir, exist_ok=True)
    value = ts.isoformat() if hasattr(ts, "isoformat") else str(ts)
    with open(os.path.join(state_dir, "watermark.txt"), "w") as f:
        f.write(value)


def assert_schema(client, db):
    """Fail closed unless the live QueryCompletion exposes every required column."""
    resp = client.execute(db, "QueryCompletion | getschema | project ColumnName")
    cols = {row["ColumnName"] for row in resp.primary_results[0]}
    missing = REQUIRED_COLUMNS - cols
    if missing:
        raise RuntimeError(
            "QueryCompletion schema drift: missing %s; live columns: %s"
            % (sorted(missing), sorted(cols)))


def build_query(watermark, cap, lag, maxlen, bootstrap):
    """Deterministic oldest-first window, cost-agnostic (calibration needs a
    representative baseline; mine.py cost-ranks downstream). Unit conversions are
    done server-side. ponytail: strict `Timestamp >` can skip exact-timestamp ties
    at the CAP boundary — switch to `>=` with per-id dedup only if volume saturates CAP."""
    lower = "todatetime('%s')" % watermark if watermark else "ago(%s)" % bootstrap
    return (
        "QueryCompletion\n"
        "| where Timestamp > %s and Timestamp <= ago(%s)\n"
        '| where isnotempty(Text) and Text != "%s"\n'
        "| where strlen(Text) < %d\n"
        "| top %d by Timestamp asc\n"
        "| project id = tostring(RequestId), Text,\n"
        "          durationMs = totimespan(Duration) / 1ms,\n"
        "          cpuMs = todouble(TotalCpuMs),\n"
        "          memoryPeakBytes = tolong(MemoryPeak),\n"
        "          scannedRows = tolong(todynamic(ScannedExtentsStatistics).ScannedRowsCount),\n"
        "          state = State, failureReason = FailureReason, Timestamp"
        % (lower, lag, REDACTED_PLACEHOLDER, maxlen, cap)
    )


def connect(cluster, client_id):
    from azure.kusto.data import KustoClient, KustoConnectionStringBuilder  # runner-only dep
    kcsb = KustoConnectionStringBuilder.with_aad_managed_service_identity_authentication(
        cluster, client_id=client_id or None)
    return KustoClient(kcsb)


def execute(client, db, query):
    resp = client.execute(db, query)
    return [{k: row[k] for k in _ROW_KEYS} for row in resp.primary_results[0]]


def main(argv, client=None):
    cluster = os.environ.get("KUSKUS_CLUSTER", DEFAULT_CLUSTER)
    db = os.environ.get("KUSKUS_DATABASE", "Kuskus")
    client_id = os.environ.get("KUSKUS_MI_CLIENT_ID")
    try:
        state_dir = os.environ["KUSKUS_STATE_DIR"]
    except KeyError:
        sys.stderr.write("fetch_corpus: KUSKUS_STATE_DIR is required\n")
        return 2
    cap = int(os.environ.get("KUSKUS_FETCH_CAP", "50000"))
    lag = os.environ.get("KUSKUS_FETCH_LAG", "1h")
    maxlen = int(os.environ.get("KUSKUS_FETCH_MAXLEN", str(DEFAULT_MAXLEN)))
    bootstrap = os.environ.get("KUSKUS_FETCH_BOOTSTRAP", "7d")
    scratch, manifest_path = "scratch", "manifest.json"

    if client is None:
        client = connect(cluster, client_id)
    try:
        assert_schema(client, db)
        rows = execute(client, db, build_query(read_watermark(state_dir), cap, lag, maxlen, bootstrap))
        manifest, max_ts = rows_to_corpus(rows, scratch, maxlen)
        with open(manifest_path, "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
        if max_ts is not None:
            advance_watermark(state_dir, max_ts)
        print(len(manifest))  # aggregate count only — never query text
        return 0
    except Exception as e:  # fail closed: drop partial output, leave watermark untouched
        shutil.rmtree(scratch, ignore_errors=True)
        if os.path.exists(manifest_path):
            os.remove(manifest_path)
        sys.stderr.write("fetch_corpus failed: %s\n" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
