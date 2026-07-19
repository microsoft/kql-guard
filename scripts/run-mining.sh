#!/usr/bin/env bash
# Runner/local mining pipeline: discover a recurring unflagged high-cost shape
# and draft + validate + (optionally) publish a new-rule PR. Dry-run by default.
#   run-mining.sh --corpus-path <dir> --manifest <manifest.json> [--apply]
#
# Only aggregate numbers + abstracted signatures ever leave the runner; the
# confidential query text stays in the corpus dir. validate-candidate.sh is the
# fail-closed gate and publish-candidate.sh is idempotent + dry-run by default.
set -euo pipefail
cd "$(dirname "$0")/.."

CORPUS=""; MANIFEST=""; APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --corpus-path) CORPUS="$2"; shift 2;;
    --manifest)    MANIFEST="$2"; shift 2;;
    --apply)       APPLY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
: "${CORPUS:?--corpus-path required}"; : "${MANIFEST:?--manifest required}"

DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"

# 1. Validate/pass-through the corpus materialized by the fetch step.
scripts/fetch-corpus.sh --corpus-path "$CORPUS" --manifest "$MANIFEST"

# 2. Analyze with shapes. A nonzero exit on query errors is expected; the JSON
#    report is still written. On the runner, KQLGUARD_BIN points at the
#    downloaded NativeAOT binary (no .NET SDK); locally we build + run the dll.
if [[ -n "${KQLGUARD_BIN:-}" ]]; then
  SCANNER=("$KQLGUARD_BIN")
else
  BIN="bin/Debug/net10.0/kql-guard.dll"
  [[ -f "$BIN" ]] || "$DOTNET" build -c Debug >/dev/null
  SCANNER=("$DOTNET" "$BIN")
fi
"${SCANNER[@]}" "$CORPUS" --format json --shapes > findings.json || true

# 3. Mine -> candidates (aggregate summary to the job summary; no query text).
{
  echo "## Kuskus shape mining (recurring unflagged high-cost shapes)"
  python3 scripts/mine.py findings.json "$MANIFEST" --top 5 --candidates-json candidates.json
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

TOP=$(python3 -c 'import json; c=json.load(open("candidates.json")); print(json.dumps(c[0]) if c else "")')
if [[ -z "$TOP" ]]; then echo "run-mining: no new-rule candidates."; rm -f candidates.json findings.json; exit 0; fi

# 4. Draft (pluggable; mock default), validate (fail-closed), publish (idempotent).
SUGGESTER_CMD="${SUGGESTER_CMD:-python3 scripts/mock-suggester.py}"
printf '%s' "$TOP" | $SUGGESTER_CMD > candidate.json

if scripts/validate-candidate.sh candidate.json "$CORPUS" "$CORPUS"; then
  if [[ "$APPLY" -eq 1 ]]; then
    scripts/publish-candidate.sh candidate.json --apply
  else
    scripts/publish-candidate.sh candidate.json
  fi
else
  echo "run-mining: top candidate did not validate; discarded."
fi
rm -f candidates.json candidate.json findings.json
