#!/usr/bin/env bash
# Fail-closed gate for an AI-drafted new-rule candidate. Applies the draft in a
# throwaway git worktree and requires ALL of: the outgoing diff is leak-clean,
# the test suite passes, the release build/publish succeeds, and the new rule
# fires on < threshold% of the corpus. Any failure discards the candidate
# (nonzero exit). Leak-guard runs first so a boundary violation fails fast,
# before any build.
#
# Usage: validate-candidate.sh <candidate.json> <corpus-dir> <scratch-dir> [--threshold PCT]
# Env:   VALIDATE_TESTS  test command run in the worktree (default ./test/run-tests.sh)
#        VALIDATE_BUILD  release build/publish command (default AOT publish)
set -uo pipefail
cd "$(dirname "$0")/.."

CAND="${1:?usage: validate-candidate.sh <candidate.json> <corpus-dir> <scratch-dir> [--threshold PCT]}"
CORPUS="${2:?corpus dir required}"
SCRATCH="${3:?scratch dir required}"
THRESHOLD=20
[[ "${4:-}" == "--threshold" ]] && THRESHOLD="${5:?}"
VALIDATE_TESTS="${VALIDATE_TESTS:-./test/run-tests.sh}"
VALIDATE_BUILD="${VALIDATE_BUILD:-dotnet publish -c Release -r linux-x64}"
DOTNET="${DOTNET:-$([[ -x "$HOME/.dotnet/dotnet" ]] && echo "$HOME/.dotnet/dotnet" || command -v dotnet)}"  # net10 at ~/.dotnet, else PATH (CI)

CAND_ABS="$(cd "$(dirname "$CAND")" && pwd)/$(basename "$CAND")"
SCRATCH_ABS="$(cd "$SCRATCH" && pwd)"
RULE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$CAND_ABS")

worktree=$(mktemp -d)
cleanup() { git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"; }
trap cleanup EXIT

git worktree add -q --detach "$worktree" HEAD || { echo "validate: worktree add failed" >&2; exit 1; }
python3 scripts/apply-candidate.py "$CAND_ABS" --root "$worktree" || { echo "validate: apply failed" >&2; exit 1; }

# 1. Leak-guard FIRST on the entire outgoing diff (cheap, fail-closed).
artifact=$(mktemp)
( cd "$worktree" && git add -A && git diff --cached ) > "$artifact"
if ! scripts/leak-guard.sh "$artifact" "$SCRATCH_ABS" >/dev/null 2>&1; then
  rm -f "$artifact"; echo "validate: leak-guard blocked -> discard" >&2; exit 1
fi
rm -f "$artifact"

# 2. Tests must pass. KUSKUS_IN_VALIDATE breaks the recursion when the worktree
#    suite itself runs test_validate_candidate.sh.
( cd "$worktree" && KUSKUS_IN_VALIDATE=1 DOTNET="$DOTNET" $VALIDATE_TESTS ) >/dev/null 2>&1 \
  || { echo "validate: tests failed -> discard" >&2; exit 1; }

# 3. Release build/publish must succeed (real AOT publish in CI; `true` in tests).
( cd "$worktree" && $VALIDATE_BUILD ) >/dev/null 2>&1 \
  || { echo "validate: release build failed -> discard" >&2; exit 1; }

# 4. Over-report: the new rule must fire on < THRESHOLD% of the corpus.
BIN="$worktree/bin/Debug/net10.0/kql-guard.dll"
[[ -f "$BIN" ]] || ( cd "$worktree" && "$DOTNET" build -c Debug >/dev/null 2>&1 )
"$DOTNET" "$BIN" "$CORPUS" --format json > "$worktree/findings.json" 2>/dev/null || true
python3 - "$worktree/findings.json" "$RULE_ID" "$THRESHOLD" <<'PY' || { echo "validate: over-reports -> discard" >&2; exit 1; }
import json, sys
doc = json.load(open(sys.argv[1])); rule, thr = sys.argv[2], float(sys.argv[3])
total = len(doc.get("costScores") or {}) or 1
hits = len({f["file"] for f in doc.get("findings", []) if f["rule"] == rule})
pct = 100.0 * hits / total
sys.exit(1 if pct >= thr else 0)
PY

echo "VALIDATED: $RULE_ID (< ${THRESHOLD}% over-report, leak-clean)"
