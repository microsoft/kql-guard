#!/usr/bin/env bash
# Self-check for _set_weight.py (edits exactly one rule entry, leaves the
# same-weight sibling untouched, deterministic) and for propose-weight.sh's
# branch topology under --apply (each proposal branches from the job base, not
# from the previous proposal's branch).
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

# Two --apply proposals in one job must each branch from the base (no stacking).
# Offline: a local bare repo is the push target and a gh stub replaces the API.
h=$(mktemp -d)
cp CostRules.cs "$h/"; mkdir -p "$h/scripts"
cp scripts/propose-weight.sh scripts/_set_weight.py "$h/scripts/"
mkdir "$h/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/gh"; chmod +x "$h/bin/gh"
(
  cd "$h"
  git init -q; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git add -A && git commit -qm base
  git init -q --bare origin.git && git remote add origin origin.git
  base=$(git rev-parse HEAD)
  PATH="$h/bin:$PATH" bash scripts/propose-weight.sh KQL003 4 ev >/dev/null 2>&1
  PATH="$h/bin:$PATH" bash scripts/propose-weight.sh KQL004 6 ev >/dev/null 2>&1
  # The second branch must hold exactly its own commit — not the first's too.
  [[ "$(git rev-list --count "$base..kuskus/weight-KQL004")" == "1" ]]
) && echo "ok: --apply proposals branch from base (no stacking)" \
  || { echo "FAIL: proposals stack onto each other"; fails=$((fails+1)); }
rm -rf "$h"

if [[ $fails -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
