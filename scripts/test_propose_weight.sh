#!/usr/bin/env bash
# Self-check for _set_weight.py: edits exactly one rule entry, leaves the
# same-weight sibling untouched, and is deterministic.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
tmp=$(mktemp --suffix=.cs)
cp CostRules.cs "$tmp"

# KQL003 and KQL004 both currently have weight 5. Change only KQL003 -> 4.
python3 scripts/_set_weight.py "$tmp" KQL003 4
if grep -q '"KQL003", "MissingTimeFilter"' "$tmp" \
   && grep -A2 '"KQL003", "MissingTimeFilter"' "$tmp" | grep -q '"warning", 4)'; then
  echo "ok: KQL003 changed to 4"
else echo "FAIL: KQL003 not set to 4"; fails=$((fails+1)); fi

if grep -A2 '"KQL004", "UnscopedSearch"' "$tmp" | grep -q '"warning", 5)'; then
  echo "ok: sibling KQL004 untouched"
else echo "FAIL: sibling KQL004 changed"; fails=$((fails+1)); fi

# Unknown rule -> non-zero exit, no write.
if python3 scripts/_set_weight.py "$tmp" KQL999 1 2>/dev/null; then
  echo "FAIL: unknown rule accepted"; fails=$((fails+1))
else echo "ok: unknown rule rejected"; fi

rm -f "$tmp"
if [[ $fails -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
