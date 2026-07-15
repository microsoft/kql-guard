#!/usr/bin/env bash
# Open (or dry-run) an idempotent new-rule PR for a validated candidate.
# Fingerprints by shape signature so a given shape yields at most one PR/branch.
# The PR carries only the abstracted shape + aggregate cost + the validated
# synthetic rule and tests — never query text.
#
# Usage: publish-candidate.sh <candidate.json> [--apply]
# Env:   PUBLISH_REMOTE_CHECK=0 skips the origin/PR existence probe (offline tests)
set -euo pipefail
cd "$(dirname "$0")/.."

CAND="${1:?usage: publish-candidate.sh <candidate.json> [--apply]}"
APPLY=0; [[ "${2:-}" == "--apply" ]] && APPLY=1
REMOTE_CHECK="${PUBLISH_REMOTE_CHECK:-1}"

read -r RULE_ID SIG COUNT MED < <(python3 - "$CAND" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c["id"], c.get("signature", ""), c.get("count", 0), c.get("medianDurationMs", 0) or 0)
PY
)
FP=$(printf '%s' "$SIG" | sha1sum | cut -c1-12)
BRANCH="kuskus/rule-${FP}"
EVIDENCE="Recurring unflagged shape (fingerprint ${FP}), count=${COUNT}, median cost=${MED}ms. Abstracted shape: \`${SIG}\`. Validated: tests + release build pass, under over-report threshold, leak-clean. Synthetic sample only."

# Idempotency: a local branch, an origin branch, or an open PR for this
# fingerprint all mean the shape was already proposed. The origin/PR probe is
# the durable cross-run signal (CI checkouts have no local branch); skip it
# offline via PUBLISH_REMOTE_CHECK=0.
already_proposed() {
  git show-ref --verify --quiet "refs/heads/${BRANCH}" && return 0
  [[ "$REMOTE_CHECK" == "1" ]] || return 1
  git ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null 2>&1 && return 0
  gh pr list --head "${BRANCH}" --state open --json number --jq 'length>0' 2>/dev/null | grep -q true
}
if already_proposed; then
  echo "publish-candidate: ${BRANCH} already exists; skipping (idempotent)."
  exit 0
fi

if [[ "$APPLY" -eq 0 ]]; then
  echo "would open PR ${BRANCH} for new rule ${RULE_ID} — ${EVIDENCE}"
  exit 0
fi

git switch -c "${BRANCH}"
python3 scripts/apply-candidate.py "$CAND"
git add -A
git commit -F - <<EOF
feat(${RULE_ID}): new rule from Kuskus shape mining

${EVIDENCE}

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Copilot-Session: b53e8451-3660-48d9-844a-cecad80cb0db
EOF
git push -u origin "${BRANCH}"
gh pr create --head "${BRANCH}" \
  --title "feat(${RULE_ID}): new rule from Kuskus shape mining" \
  --body "${EVIDENCE} Human review required before merge."
