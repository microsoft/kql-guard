#!/usr/bin/env bash
# Self-check for kql-guard's static analysis rules. No framework: each sample is
# a single query that should trigger exactly one rule (or none, for clean.kql).
# Run: ./test/run-tests.sh   (builds Debug first if needed)
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="bin/Debug/net8.0/kql-guard.dll"
if [[ ! -f "$BIN" ]]; then
  dotnet build -c Debug >/dev/null || { echo "build failed"; exit 1; }
fi
RUN() { dotnet "$BIN" "$@" 2>&1; }

fails=0
# assert_contains <label> <needle> <haystack>
assert_contains() {
  if [[ "$3" != *"$2"* ]]; then
    echo "FAIL: $1 — expected to contain: $2"
    echo "  got: $3"
    fails=$((fails+1))
  else
    echo "ok: $1"
  fi
}
# assert_exit <label> <expected> <actual>
assert_exit() {
  if [[ "$3" != "$2" ]]; then
    echo "FAIL: $1 — expected exit $2, got $3"; fails=$((fails+1))
  else
    echo "ok: $1 (exit $3)"
  fi
}

S=samples/cost
assert_contains "KQL002 contains"      "KQL002" "$(RUN $S/contains.kql)"
assert_contains "KQL003 no-timefilter" "KQL003" "$(RUN $S/no-timefilter.kql)"
assert_contains "KQL004 search"        "KQL004" "$(RUN $S/search-star.kql)"
assert_contains "KQL005 union"         "KQL005" "$(RUN $S/union-star.kql)"
assert_contains "KQL006 join"          "KQL006" "$(RUN $S/unwindowed-join.kql)"
assert_contains "KQL007 regex"         "KQL007" "$(RUN $S/regex.kql)"
assert_contains "KQL008 no-reduction"  "KQL008" "$(RUN $S/no-reduction.kql)"
assert_contains "KQL009 mv-expand"     "KQL009" "$(RUN $S/unbounded-mvexpand.kql)"
assert_contains "KQL010 cross-cluster" "KQL010" "$(RUN $S/cross-cluster.kql)"

# Clean query: no findings, score 0.
clean=$(RUN $S/clean.kql)
assert_contains "clean scores 0" "cost score 0" "$clean"
if [[ "$clean" == *"warning"* || "$clean" == *"error"* ]]; then
  echo "FAIL: clean.kql produced a finding"; echo "  got: $clean"; fails=$((fails+1))
else
  echo "ok: clean has no findings"
fi

# Score sums correctly (KQL003 5 + KQL006 3 = 8).
assert_contains "score sums (join file = 8)" "cost score 8" "$(RUN $S/unwindowed-join.kql)"

# Budget gate: breach exits 1, within-budget does not gate.
RUN $S/no-timefilter.kql --max-cost 4 >/dev/null; assert_exit "budget breach" 1 $?
RUN $S/clean.kql --max-cost 10 >/dev/null;        assert_exit "within budget" 0 $?

# SARIF stays valid and lists the new rules.
sarif=$(RUN $S/ --format sarif)
if python3 - "$sarif" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); r=d["runs"][0]
ids=[x["id"] for x in r["tool"]["driver"]["rules"]]
assert "KQL008" in ids, ids
assert "costScores" in r["properties"], r["properties"]
print("ok: SARIF valid with KQL003-008 + costScores")
PY
then :; else fails=$((fails+1)); fi

# Offline enrichment: per-table size factor scales scan weights (5 * 10 = 50).
sizes=$(mktemp --suffix=.json); echo '{"SecurityEvent":10}' > "$sizes"
assert_contains "enrich scales score" "cost score 50" "$(RUN $S/no-timefilter.kql --table-sizes "$sizes")"
rm -f "$sizes"

# Formatter: --check flags unformatted, --write fixes, then idempotent.
tmp=$(mktemp --suffix=.kql)
printf 'SecurityEvent|where EventID==4688|project   x,y|take 5\n' > "$tmp"
RUN fmt "$tmp" --check >/dev/null; assert_exit "fmt --check unformatted" 1 $?
RUN fmt "$tmp" --write >/dev/null; assert_exit "fmt --write" 0 $?
RUN fmt "$tmp" --check >/dev/null; assert_exit "fmt --check after write" 0 $?
assert_contains "fmt pipe-per-line" "| where EventID == 4688" "$(cat "$tmp")"
rm -f "$tmp"

echo "----"
if [[ $fails -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
