#!/usr/bin/env bash
# Fail if any 8-token run (shingle) of any scratch/*.kql query text appears in
# the artifact. This is the last line of defense keeping confidential query
# text from crossing into the public repo. Fails closed.
set -uo pipefail
ARTIFACT="${1:?usage: leak-guard.sh <artifact-file> <scratch-dir>}"
SCRATCH="${2:?usage: leak-guard.sh <artifact-file> <scratch-dir>}"

python3 - "$ARTIFACT" "$SCRATCH" <<'PY'
import glob, os, sys
artifact = " ".join(open(sys.argv[1], encoding="utf-8", errors="replace").read().split())
K = 8
for path in glob.glob(os.path.join(sys.argv[2], "**", "*.kql"), recursive=True):
    toks = open(path, encoding="utf-8", errors="replace").read().split()
    # ponytail: short queries (< K tokens) still get scanned as a single whole-text
    # shingle — otherwise a verbatim <8-token confidential query would slip past.
    k = min(K, len(toks))
    for i in range(len(toks) - k + 1):
        shingle = " ".join(toks[i:i + k])
        if shingle and shingle in artifact:
            sys.stderr.write(f"LEAK: {os.path.basename(path)} :: {shingle[:60]}...\n")
            sys.exit(1)
print("leak-guard: clean")
PY
