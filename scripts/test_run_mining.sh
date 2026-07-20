#!/usr/bin/env bash
# Regression guard for the runner mining path: when KQLGUARD_BIN is set (the
# runner/offline seam), run-mining.sh must NOT require a .NET SDK. A prior
# regression resolved $DOTNET unconditionally, so `set -e` aborted the whole
# script in ~14ms with no output when no dotnet was on PATH — exactly the live
# self-hosted-runner environment. This reproduces that env (KQLGUARD_BIN set, a
# stub scanner, a PATH/HOME with no dotnet) and asserts the pipeline runs to
# completion instead of aborting at the DOTNET line.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0

shimbin=$(mktemp -d); emptyhome=$(mktemp -d)
cleanup() { rm -rf "$shimbin" "$emptyhome" findings.json candidates.json candidate.json; }
trap cleanup EXIT

# Stub scanner: emits an empty findings doc so mine.py yields zero candidates and
# run-mining exits cleanly at "no new-rule candidates" — before validate (which
# legitimately needs the SDK). Absolute path; /bin/sh shebang has no PATH dep.
stub="$shimbin/kql-guard-stub"
cat > "$stub" <<'SH'
#!/bin/sh
printf '%s\n' '{"findings":[],"costScores":{},"shapes":{}}'
SH
chmod +x "$stub"

# A PATH with every tool the pipeline needs EXCEPT dotnet, so `command -v dotnet`
# fails (reproducing the SDK-less runner even though this box has a system dotnet).
for t in bash sh env python3 find wc rm tee dirname cat mktemp grep sed; do
  p=$(command -v "$t") && ln -s "$p" "$shimbin/$t"
done

out=$(PATH="$shimbin" HOME="$emptyhome" GITHUB_STEP_SUMMARY=/dev/null \
      KQLGUARD_BIN="$stub" \
      "$shimbin/bash" scripts/run-mining.sh \
        --corpus-path test/fixtures/mining/corpus \
        --manifest    test/fixtures/mining/manifest.json 2>&1)
rc=$?

if [[ $rc -eq 0 && "$out" == *"no new-rule candidates"* ]]; then
  echo "ok: KQLGUARD_BIN set + no SDK -> mining runs (no set -e abort)"
else
  echo "FAIL: run-mining aborted without an SDK (rc=$rc)"; echo "  out: $out"
  fails=$((fails+1))
fi

# Root cause directly: with KQLGUARD_BIN set, dotnet must never be resolved.
if grep -qi 'dotnet' <<<"$out"; then
  echo "FAIL: pipeline referenced dotnet with KQLGUARD_BIN set"; fails=$((fails+1))
fi

if [[ $fails -eq 0 ]]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
