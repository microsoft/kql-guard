#!/usr/bin/env bash
# Local/runner calibration pipeline. Deterministic weight review; no AI.
#   run-calibration.sh --corpus-path <dir> --manifest <manifest.json> [--apply]
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

# 1. Validate/pass-through the corpus materialized by the fetch step.
scripts/fetch-corpus.sh --corpus-path "$CORPUS" --manifest "$MANIFEST"

# 2. kql-guard over the corpus. Exit 1 is expected when queries carry errors;
#    the JSON is still written, so ignore the exit code here. KQLGUARD_BIN is an
#    optional prebuilt-binary override; unset — on the runner and in CI — we
#    build + run the Debug dll with the SDK.
if [[ -n "${KQLGUARD_BIN:-}" ]]; then
  SCANNER=("$KQLGUARD_BIN")
else
  DOTNET="${DOTNET:-$([[ -x "$HOME/.dotnet/dotnet" ]] && echo "$HOME/.dotnet/dotnet" || command -v dotnet)}"  # net10 at ~/.dotnet, else PATH (CI)
  BIN="bin/Debug/net10.0/kql-guard.dll"
  [[ -f "$BIN" ]] || "$DOTNET" build -c Debug >/dev/null
  SCANNER=("$DOTNET" "$BIN")
fi
"${SCANNER[@]}" "$CORPUS" --format json > findings.json || true

# 3. Correlate. report.md is the job summary; report.json is machine-readable.
python3 scripts/calibrate.py findings.json "$MANIFEST" --json report.json > report.md
cat report.md

# 4. Weight candidates -> PRs (or dry-run print).
python3 - <<'PY' > candidates.tsv
import json
r = json.load(open("report.json"))
for f in r.get("weightReview", []):
    # up-weight = +1, down-weight = -1 relative to current declared weight.
    delta = 1 if f["suggest"] == "up-weight" else -1
    new = max(1, f["weight"] + delta)
    print(f"{f['rule']}\t{new}\tmedian={f['medianDurationMs']:.0f}ms costRank={f['costRank']} weightRank={f['weightRank']}")
PY

if [[ ! -s candidates.tsv ]]; then
  echo "run-calibration: no weight candidates."
else
  while IFS=$'\t' read -r rule new evidence; do
    if [[ "$APPLY" -eq 1 ]]; then
      scripts/propose-weight.sh "$rule" "$new" "$evidence"
    else
      echo "would propose: $rule -> weight $new ($evidence)"
    fi
  done < candidates.tsv
fi
rm -f candidates.tsv
