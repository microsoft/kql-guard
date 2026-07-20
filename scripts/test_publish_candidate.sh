#!/usr/bin/env bash
# Self-check for publish-candidate.sh: dry-run prints the shape fingerprint and
# intent, the fingerprint is deterministic per signature, and the output carries
# NO query text (only the abstracted signature + aggregates cross the boundary).
# PUBLISH_REMOTE_CHECK=0 keeps the probe fully offline (no git ls-remote / gh).
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0

cand=$(mktemp --suffix=.json)
python3 scripts/mock-suggester.py <<<'{"signature":"A;facet;","count":7,"medianDurationMs":1500}' > "$cand"

out=$(PUBLISH_REMOTE_CHECK=0 bash scripts/publish-candidate.sh "$cand" 2>&1)
case "$out" in
  *"kuskus/rule-"*) echo "ok: prints fingerprint branch" ;;
  *) echo "FAIL: no fingerprint branch in: $out"; fails=$((fails+1)) ;;
esac
case "$out" in
  *"would open PR"*) echo "ok: dry-run intent" ;;
  *) echo "FAIL: no dry-run intent"; fails=$((fails+1)) ;;
esac

# Boundary: the dry-run output must not echo the candidate's sample query text.
case "$out" in
  *SyntheticEvents*) echo "FAIL: sample query text leaked into PR intent"; fails=$((fails+1)) ;;
  *) echo "ok: no query text in output" ;;
esac

# Fingerprint is deterministic for a given signature.
out2=$(PUBLISH_REMOTE_CHECK=0 bash scripts/publish-candidate.sh "$cand" 2>&1)
fp1=$(sed -n 's/.*\(kuskus\/rule-[0-9a-f]*\).*/\1/p' <<<"$out"  | head -1)
fp2=$(sed -n 's/.*\(kuskus\/rule-[0-9a-f]*\).*/\1/p' <<<"$out2" | head -1)
[[ -n "$fp1" && "$fp1" == "$fp2" ]] && echo "ok: deterministic fingerprint" || { echo "FAIL: fingerprint not stable ($fp1 vs $fp2)"; fails=$((fails+1)); }

rm -f "$cand"
[[ $fails -eq 0 ]] && echo "publish-candidate self-check: PASS" || { echo "publish-candidate self-check: $fails FAILED"; exit 1; }
