# Cost manifest contract

The fetch step writes two things per query drawn from ADX `QueryCompletion`:

1. `scratch/<id>.kql` — the query `Text`. `<id>` is an opaque per-row id
   (hash/GUID), never derived from query content. Git-ignored; never leaves
   the runner.
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
