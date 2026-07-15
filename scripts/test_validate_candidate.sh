#!/usr/bin/env bash
# Self-check for validate-candidate.sh. Asserts each gate discards for the RIGHT
# reason (stderr), not merely that the script exited nonzero (a missing script
# would do that too), plus one happy-path VALIDATED case. Injects a no-op test
# suite (VALIDATE_TESTS) and build (VALIDATE_BUILD) so only the over-report and
# happy-path cases build (once each, Debug); leak/test-gate cases are build-free
# because leak-guard runs first.
set -uo pipefail
cd "$(dirname "$0")/.."

# When the worktree suite invokes us from inside a running validation, skip to
# avoid recursing into another worktree build.
[[ -n "${KUSKUS_IN_VALIDATE:-}" ]] && { echo "ok: validate-candidate (skipped: nested)"; exit 0; }

fails=0
work=$(mktemp -d)
scratch="$work/scratch"; mkdir -p "$scratch"
printf 'T | where X > ago(1d) | facet by Y\n' > "$scratch/hit.kql"    # triggers KQL014
printf 'T | where X > ago(1d) | project Y\n'  > "$scratch/clean.kql"  # clean
python3 scripts/mock-suggester.py <<<'{"signature":"A;facet;"}' > "$work/cand.json"

# run_validate VAR=.. VAR=.. -- <validate args...>  (env assignments exported to the child)
run_validate() {
  local envs=(); while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
  env "${envs[@]}" bash scripts/validate-candidate.sh "$work/cand.json" "$scratch" "$scratch" "$@"
}

# Happy path: clean synthetic sample, generous threshold -> VALIDATED (exit 0). [builds once]
out=$(run_validate VALIDATE_TESTS=true VALIDATE_BUILD=true -- --threshold 99 2>&1); rc=$?
{ [[ $rc -eq 0 && "$out" == *"VALIDATED"* ]] && echo "ok: happy path validates"; } || { echo "FAIL: happy path ($rc): $out"; fails=$((fails+1)); }

# Test gate: failing suite discards, before any build. [no build]
out=$(run_validate VALIDATE_TESTS=false VALIDATE_BUILD=true -- --threshold 99 2>&1); rc=$?
{ [[ $rc -ne 0 && "$out" == *"tests failed"* ]] && echo "ok: failing tests discard"; } || { echo "FAIL: test gate ($rc): $out"; fails=$((fails+1)); }

# Over-report gate: rule fires on 1/2 = 50% >= 40% -> discard. [builds]
out=$(run_validate VALIDATE_TESTS=true VALIDATE_BUILD=true -- --threshold 40 2>&1); rc=$?
{ [[ $rc -ne 0 && "$out" == *"over-reports"* ]] && echo "ok: over-report discards"; } || { echo "FAIL: over-report ($rc): $out"; fails=$((fails+1)); }

# Leak gate: sample copies corpus text verbatim -> blocked first, before any build. [no build]
python3 - "$work/cand.json" "$scratch/hit.kql" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["sample"] = open(sys.argv[2]).read()
json.dump(c, open(sys.argv[1], "w"))
PY
out=$(run_validate VALIDATE_TESTS=true VALIDATE_BUILD=true -- --threshold 99 2>&1); rc=$?
{ [[ $rc -ne 0 && "$out" == *"leak-guard blocked"* ]] && echo "ok: leak-guard discards"; } || { echo "FAIL: leak gate ($rc): $out"; fails=$((fails+1)); }

rm -rf "$work"
[[ $fails -eq 0 ]] && echo "validate-candidate self-check: PASS" || { echo "validate-candidate self-check: $fails FAILED"; exit 1; }
