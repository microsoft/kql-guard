# Cost manifest contract

The fetch step writes two things per query drawn from ADX `QueryCompletion`:

1. `scratch/<id>.kql` — the query `Text`. `<id>` is `tostring(RequestId)`, an
   opaque per-row id, never derived from query content. Git-ignored; never
   leaves the runner.
2. `manifest.json` — one entry per `<id>`, cost only, no text:

```json
{
  "<id>": {
    "durationMs":      123.4,        // totimespan(QueryCompletion.Duration) / 1ms  (Duration is a timespan)
    "cpuMs":           456.7,        // QueryCompletion.TotalCpuMs  (already ms)
    "memoryPeakBytes": 789012,       // QueryCompletion.MemoryPeak  (long, bytes)
    "scannedRows":     3456789,      // todynamic(QueryCompletion.ScannedExtentsStatistics).ScannedRowsCount
    "state":           "Completed",  // or "Failed"
    "failureReason":   null          // QueryCompletion.FailureReason when Failed
  }
}
```

Join key: kql-guard reports `findings[].file` and `costScores` keys as the
path it scanned (`scratch/<id>.kql`); `<id> = basename without ".kql"`.

Row selection is identical for confidential and redacted traces — rows whose
`Text` is the redacted placeholder or an expanded-dialect form (markers
`__invoke(`, `["`, `assert-schema`, `$matchesregex`) are skipped by the fetch,
so downstream scripts never depend on text being present.

## Fetch source

`scripts/fetch_corpus.py` produces the corpus above. It queries ADX
`QueryCompletion` on `KUSKUS_CLUSTER` (default
`https://kuskushead.westeurope.kusto.windows.net`, database `Kuskus`) via
managed-identity auth, oldest-first from a durable watermark. `fetch-corpus.sh`
dispatches to it when no `--corpus-path` is given; with `--corpus-path` it
validates and passes a pre-materialized corpus through (the offline test seam).

It depends on the Kusto SDK, pinned **`azure-kusto-data==6.0.4`**. This is a
**runner-only** dependency, installed on the self-hosted runner image — it is
reflection-based and is deliberately kept out of the NativeAOT binary and out of
the stdlib-only `calibrate.py` / `mine.py`.
