#!/usr/bin/env bash
# Fetch a QueryCompletion corpus into scratch/<id>.kql + manifest.json.
#
# The real ADX fetch is deferred to a later change (it needs Kuskus cluster
# access + auth wiring). This stub fails closed so the pipeline can never
# silently run on an empty corpus. For testing/local runs, pass a
# pre-materialized corpus with --corpus-path <dir> --manifest <file>; the stub
# then just validates and passes those through.
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
  echo "fetch-corpus: real ADX fetch not yet implemented." >&2
  echo "  Provide a pre-materialized corpus for now:" >&2
  echo "    fetch-corpus.sh --corpus-path <dir of .kql> --manifest <manifest.json>" >&2
  echo "  See scripts/manifest.schema.md for the manifest contract." >&2
  exit 1
fi
[[ -d "$CORPUS_PATH" ]] || { echo "corpus dir not found: $CORPUS_PATH" >&2; exit 1; }
[[ -f "$MANIFEST"    ]] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
count=$(find "$CORPUS_PATH" -name '*.kql' | wc -l)
[[ "$count" -gt 0 ]] || { echo "no .kql files in $CORPUS_PATH" >&2; exit 1; }
echo "fetch-corpus: using $count query files from $CORPUS_PATH (manifest: $MANIFEST)"
