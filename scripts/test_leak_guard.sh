#!/usr/bin/env bash
# Self-check for leak-guard.sh: a verbatim query run is blocked; unrelated
# synthetic text passes.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
tmp=$(mktemp -d)
mkdir -p "$tmp/scratch"
printf 'StormEvents | where State == "TEXAS" and EventType == "Tornado" | take 10\n' > "$tmp/scratch/q1.kql"

# 1. Artifact that quotes the query verbatim -> must FAIL (exit 1).
printf '+ StormEvents | where State == "TEXAS" and EventType == "Tornado" | take 10\n' > "$tmp/leaky.diff"
bash scripts/leak-guard.sh "$tmp/leaky.diff" "$tmp/scratch" >/dev/null 2>&1
if [[ $? -eq 1 ]]; then echo "ok: verbatim leak blocked"; else echo "FAIL: leak not caught"; fails=$((fails+1)); fi

# 2. Artifact with only aggregate numbers -> must PASS (exit 0).
printf 'KQL003 fires 42 times, median 900ms\n' > "$tmp/clean.diff"
bash scripts/leak-guard.sh "$tmp/clean.diff" "$tmp/scratch" >/dev/null 2>&1
if [[ $? -eq 0 ]]; then echo "ok: aggregate report passes"; else echo "FAIL: false positive"; fails=$((fails+1)); fi

rm -rf "$tmp"
if [[ $fails -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
