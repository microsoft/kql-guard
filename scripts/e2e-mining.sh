#!/usr/bin/env bash
# End-to-end check of the Kuskus mining pipeline against the committed fixture:
# a recurring, unflagged, expensive `facet` shape must be mined, drafted by the
# mock, validated (fail-closed), and reach the publish step (dry-run) — and NO
# corpus identifier may appear anywhere in the output.
#
# Manual / on-demand: this does a real worktree build inside validate-candidate,
# so it is intentionally NOT wired into the fast test/run-tests.sh. Export
# VALIDATE_TESTS=true VALIDATE_BUILD=true to stub the worktree suite + AOT
# publish (the leak-guard + over-report gates still run) for a fast pass.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0

out=$(GITHUB_STEP_SUMMARY=/dev/null PUBLISH_REMOTE_CHECK=0 \
      bash scripts/run-mining.sh \
        --corpus-path test/fixtures/mining/corpus \
        --manifest    test/fixtures/mining/manifest.json 2>&1)
echo "$out"
echo "----"

# 1. The recurring expensive facet shape must validate and reach publish dry-run.
case "$out" in
  *"would open PR kuskus/rule-"*"KQL014"*) echo "ok: mined + validated -> publish dry-run" ;;
  *) echo "FAIL: pipeline did not reach a validated publish dry-run"; fails=$((fails+1)) ;;
esac

# 2. Boundary: no corpus table/column identifier may appear as a whole word.
#    (Whole-word match so the abstract signature's TokenName/NameReference kinds
#    are not mistaken for the corpus 'Name' column.)
for leak in Events Logs Requests Region Level Timestamp Name Duration ResultCode; do
  if grep -Ewq "$leak" <<<"$out"; then echo "FAIL LEAK: corpus identifier '$leak' in output"; fails=$((fails+1)); fi
done
[[ $fails -eq 0 ]] && echo "ok: boundary-safe (no corpus identifiers in output)"

echo "===="
[[ $fails -eq 0 ]] && echo "e2e-mining: PASS" || { echo "e2e-mining: $fails FAILED"; exit 1; }
