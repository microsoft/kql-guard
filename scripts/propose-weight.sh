#!/usr/bin/env bash
# Open a mechanical CostWeight-change PR for one rule. No AI, no query text —
# just "rule X: weight A -> B, because measured cost rank Y". Idempotent.
#
# Usage: propose-weight.sh <ruleId> <newWeight> [evidence-line]
set -euo pipefail
RULE="${1:?usage: propose-weight.sh <ruleId> <newWeight> [evidence]}"
NEW="${2:?usage: propose-weight.sh <ruleId> <newWeight> [evidence]}"
EVIDENCE="${3:-calibration weight-review}"
BRANCH="kuskus/weight-${RULE}"

if git show-ref --verify --quiet "refs/heads/${BRANCH}" \
   || gh pr list --head "${BRANCH}" --state open --json number --jq 'length>0' | grep -q true; then
  echo "propose-weight: ${BRANCH} already exists; skipping (idempotent)."
  exit 0
fi

OLD=$(python3 - "$RULE" <<'PY'
import re, sys
rule = sys.argv[1]
src = open("CostRules.cs", encoding="utf-8").read()
m = re.search(r'new\("' + re.escape(rule) + r'",.*?"(?:error|warning)",\s*(\d+)\s*\)', src, re.S)
print(m.group(1) if m else "")
PY
)
[[ -n "$OLD" ]] || { echo "propose-weight: rule ${RULE} not found in CostRules.cs" >&2; exit 1; }

git switch -c "${BRANCH}"
python3 scripts/_set_weight.py CostRules.cs "${RULE}" "${NEW}"
git add CostRules.cs
git commit -F - <<EOF
tune(${RULE}): CostWeight ${OLD} -> ${NEW}

${EVIDENCE}. Mechanical weight change from Kuskus calibration; aggregate cost
evidence only, no query text. Human review required before merge.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Copilot-Session: b53e8451-3660-48d9-844a-cecad80cb0db
EOF
git push -u origin "${BRANCH}"
gh pr create --fill --head "${BRANCH}" \
  --title "tune(${RULE}): CostWeight ${OLD} -> ${NEW}" \
  --body "${EVIDENCE}. Mechanical weight change from Kuskus calibration; aggregate cost evidence only. Human review required."
