#!/usr/bin/env bash
# Self-check for kql-guard's static analysis rules. No framework: each sample is
# a single query that should trigger exactly one rule (or none, for clean.kql).
# Run: ./test/run-tests.sh   (builds Debug first if needed)
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="bin/Debug/net10.0/kql-guard.dll"
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
assert_contains "KQL011 sort"          "KQL011" "$(RUN $S/unbounded-sort.kql)"
assert_contains "KQL012 casefold"      "KQL012" "$(RUN $S/casefold-take.kql)"
assert_contains "KQL013 take-nosort"   "KQL013" "$(RUN $S/casefold-take.kql)"

# Clean query: no findings, score 0.
clean=$(RUN $S/clean.kql)
assert_contains "clean scores 0" "cost score 0" "$clean"
if [[ "$clean" == *"warning"* || "$clean" == *"error"* ]]; then
  echo "FAIL: clean.kql produced a finding"; echo "  got: $clean"; fails=$((fails+1))
else
  echo "ok: clean has no findings"
fi

# Schema validation: --schema flags unknown columns; valid query and no-schema stay clean.
SC=samples/schema
assert_contains "KQL101 unknown col" "KQL101" "$(RUN $SC/unknown-col.kql --schema $SC/sentinel-schema.json)"
if RUN $SC/valid.kql --schema $SC/sentinel-schema.json | grep -q KQL101; then echo "FAIL: schema false positive"; fails=$((fails+1)); else echo "ok: valid query passes schema"; fi
if RUN $SC/unknown-col.kql | grep -q KQL101; then echo "FAIL: KQL101 without schema"; fails=$((fails+1)); else echo "ok: no schema, no semantic check"; fi

# Score sums correctly (KQL003 5 + KQL006 3 = 8).
assert_contains "score sums (join file = 8)" "cost score 8" "$(RUN $S/unwindowed-join.kql)"

# Budget gate: breach exits 1, within-budget does not gate.
RUN $S/no-timefilter.kql --max-cost 4 >/dev/null; assert_exit "budget breach" 1 $?
RUN $S/clean.kql --max-cost 10 >/dev/null;        assert_exit "within budget" 0 $?

# Exit-code model: cost warnings are advisory (exit 0 alone); --strict gates them;
# real errors (syntax/schema) and budget breaches always fail.
RUN $S/casefold-take.kql >/dev/null;          assert_exit "warning advisory (no gate)" 0 $?
RUN $S/casefold-take.kql --strict >/dev/null; assert_exit "warning fails under --strict" 1 $?
RUN $SC/unknown-col.kql --schema $SC/sentinel-schema.json >/dev/null; assert_exit "schema error fails" 1 $?
synbad=$(mktemp --suffix=.kql); printf 'MyTable | wheree x == 1\n' > "$synbad"
RUN "$synbad" >/dev/null; assert_exit "syntax error fails" 1 $?
rm -f "$synbad"

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

# Live schema pull: parse a captured `.show database schema as json` response
# offline, write an object-form --schema file, and bind a stored-function call.
pull=$(mktemp --suffix=.json)
RUN pull --from-response $SC/show-schema-response.json --database TestDB -o "$pull" >/dev/null
assert_contains "pull writes functions" '"functions"' "$(cat "$pull")"
assert_contains "pull maps column type" '"type": "datetime"' "$(cat "$pull")"
funcout=$(RUN $SC/func-call.kql --schema "$pull")
if [[ "$funcout" == *"KQL101"* ]]; then
  echo "FAIL: pulled function flagged KQL101"; echo "  got: $funcout"; fails=$((fails+1))
else echo "ok: pulled function binds clean"; fi
assert_contains "unknown column still flagged with pulled schema" "KQL101" "$(RUN $SC/unknown-col.kql --schema "$pull")"
rm -f "$pull"

# Missing token in live mode is a usage error (exit 2); no network is attempted.
RUN pull --cluster https://x.kusto.windows.net --database D >/dev/null 2>&1
assert_exit "pull missing token" 2 $?

# Sizes: integer factor = round(size / baseline), clamped to >= 1.
szf=$(mktemp --suffix=.json)
RUN pull --from-response $SC/show-schema-response.json \
  --sizes-from-response $SC/show-tables-details-response.json \
  --with-sizes "$szf" --size-baseline 1000000000 --database TestDB -o /dev/null >/dev/null
assert_contains "size factor for large table" '"SecurityEvent": 5' "$(cat "$szf")"
assert_contains "size factor clamped to 1"   '"Heartbeat": 1'     "$(cat "$szf")"
rm -f "$szf"

# Sentinel YAML: extract embedded query and map findings to the YAML's own rows.
assert_contains "yaml KQL002 line 6" "sentinel-rule.yaml(6," "$(RUN samples/sentinel-rule.yaml)"

# Baseline: record current findings, then a clean rescan reports none.
bl=$(mktemp); RUN $S/unwindowed-join.kql --write-baseline --baseline "$bl" >/dev/null
out=$(RUN $S/unwindowed-join.kql --baseline "$bl")
if [[ "$out" == *"KQL"* ]]; then echo "FAIL: baseline didn't suppress"; fails=$((fails+1)); else echo "ok: baseline suppresses known"; fi
rm -f "$bl"

# Formatter: --check flags unformatted, --write fixes, then idempotent.
tmp=$(mktemp --suffix=.kql)
printf 'SecurityEvent|where EventID==4688|project   x,y|take 5\n' > "$tmp"
RUN fmt "$tmp" --check >/dev/null; assert_exit "fmt --check unformatted" 1 $?
RUN fmt "$tmp" --write >/dev/null; assert_exit "fmt --write" 0 $?
RUN fmt "$tmp" --check >/dev/null; assert_exit "fmt --check after write" 0 $?
assert_contains "fmt pipe-per-line" "| where EventID == 4688" "$(cat "$tmp")"
rm -f "$tmp"

# --shapes: structurally identical queries share a signature; identifiers/literals never leak.
echo "--- shape signatures ---"
shp=$(RUN test/fixtures/shapes --format json --shapes)
if python3 - "$shp" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
sh = doc.get("shapes") or {}
a = sh.get("test/fixtures/shapes/a.kql"); b = sh.get("test/fixtures/shapes/b.kql"); c = sh.get("test/fixtures/shapes/c.kql")
ok = True
if a is None or b is None or c is None: print("missing shapes:", list(sh)); ok = False
if a != b: print("a/b should match"); ok = False
if a == c: print("a/c should differ"); ok = False
blob = json.dumps(sh)
for leak in ("StormEvents", "Traffic", "kansas", "tokyo", "SecretCol"):
    if leak in blob: print("LEAK:", leak); ok = False
sys.exit(0 if ok else 1)
PY
then echo "ok: --shapes signatures"; else echo "FAIL: --shapes signatures"; fails=$((fails+1)); fi

# --- Kuskus calibration pipeline self-checks (Python stdlib + shell) ---
echo "--- calibration scripts ---"
python3 scripts/test_calibrate.py     || fails=$((fails+1))
python3 scripts/test_fetch_corpus.py  || fails=$((fails+1))
bash    scripts/test_leak_guard.sh    || fails=$((fails+1))
bash    scripts/test_propose_weight.sh || fails=$((fails+1))
python3 scripts/test_mine.py          || fails=$((fails+1))
bash    scripts/test_run_mining.sh    || fails=$((fails+1))
python3 scripts/test_aoai_suggester.py || fails=$((fails+1))
python3 scripts/test_apply_candidate.py || fails=$((fails+1))
bash    scripts/test_validate_candidate.sh || fails=$((fails+1))
bash    scripts/test_publish_candidate.sh || fails=$((fails+1))

echo "----"
if [[ $fails -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
