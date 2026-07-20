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

# Idempotent: a local branch, a pushed remote branch, or an open PR all mean
# this weight was already proposed. The remote-branch probe is the durable
# cross-run signal — a CI checkout has no local ref, and (option 3) PRs are
# opened by a human later, so without it a re-run before the PR exists would
# re-push and fail non-fast-forward.
if git show-ref --verify --quiet "refs/heads/${BRANCH}" \
   || git ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null 2>&1 \
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

# Branch each PR from the pristine job base and restore HEAD afterward, so
# sibling proposals in the same --apply run each branch from the base instead of
# stacking onto the previous proposal's branch.
BASE=$(git rev-parse HEAD)
trap 'git switch --detach "$BASE" >/dev/null 2>&1 || true' EXIT
git switch -c "${BRANCH}" "${BASE}"
python3 scripts/_set_weight.py CostRules.cs "${RULE}" "${NEW}"
git add CostRules.cs
git commit -F - <<EOF
tune(${RULE}): CostWeight ${OLD} -> ${NEW}

${EVIDENCE}. Mechanical weight change from Kuskus calibration; aggregate cost
evidence only, no query text. Human review required before merge.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
EOF
git push -u origin "${BRANCH}"
# Org policy blocks Actions from opening PRs (and caps tokens at 8 days), so
# surface the compare link for a human to open — their PR triggers CI, and the
# branch's single commit message pre-fills the title/body. The idempotency
# check above skips this branch on re-runs until the PR is opened and merged.
url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-microsoft/kql-guard}/compare/main...${BRANCH}?expand=1"
echo "propose-weight: pushed ${BRANCH} — open a PR: ${url}"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] &&
  printf -- '- **%s** CostWeight %s → %s: [open PR](%s)\n' "$RULE" "$OLD" "$NEW" "$url" >> "$GITHUB_STEP_SUMMARY"
