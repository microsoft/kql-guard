#!/usr/bin/env bash
# Fetch a QueryCompletion corpus into scratch/<id>.kql + manifest.json.
#
# Two modes:
#   --corpus-path <dir> --manifest <file>  validate + pass a pre-materialized
#       corpus through (the offline test/e2e seam; contacts no cluster).
#   (no args)  run the real ADX fetch (scripts/fetch_corpus.py) using the
#       KUSKUS_* runner environment. The fetch is a script, not binary code,
#       because the Kusto SDK is reflection-based and cannot live in the
#       NativeAOT binary. See scripts/manifest.schema.md for the contract.
set -euo pipefail

CORPUS_PATH=""; MANIFEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --corpus-path) CORPUS_PATH="$2"; shift 2;;
    --manifest)    MANIFEST="$2";    shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$CORPUS_PATH" ]]; then
  exec python3 "$(dirname "$0")/fetch_corpus.py"   # real fetch; config from KUSKUS_* env
fi
[[ -d "$CORPUS_PATH" ]] || { echo "corpus dir not found: $CORPUS_PATH" >&2; exit 1; }
[[ -f "$MANIFEST"    ]] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
count=$(find "$CORPUS_PATH" -name '*.kql' | wc -l)
[[ "$count" -gt 0 ]] || { echo "no .kql files in $CORPUS_PATH" >&2; exit 1; }
echo "fetch-corpus: using $count query files from $CORPUS_PATH (manifest: $MANIFEST)"
