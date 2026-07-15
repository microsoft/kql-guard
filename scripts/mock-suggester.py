#!/usr/bin/env python3
"""Deterministic in-boundary mock suggester (scripts/suggest-rule.md contract).

Emits a fixed, synthetic, known-good candidate rule regardless of input, so the
whole mining -> validate -> publish path is runnable and testable with no
external model call. It echoes back the input signature for PR fingerprinting.
The real provider (deferred) swaps in via SUGGESTER_CMD, honoring the same
contract.
"""
import json
import sys

# A real, currently-unflagged, structurally-trivial cost pattern: an unscoped
# 'facet', which computes a per-column breakdown. Synthetic sample; the analyzer
# block follows the single-GetDescendants template used by KQL002/004/005/007.
ANALYZER_BLOCK = (
    "        // KQL014: 'facet' computes a per-column breakdown and can be expensive.\n"
    "        foreach (var facet in root.GetDescendants<FacetOperator>())\n"
    "        {\n"
    "            violations.Add(Make(code, filePath, facet.TextStart, \"KQL014\",\n"
    "                \"'facet' computes a breakdown per column and is expensive; scope or remove it.\"));\n"
    "        }\n"
)
SAMPLE = (
    "// KQL014: facet\n"
    "SyntheticEvents\n"
    "| where StartTime > ago(1d)\n"
    "| facet by Category\n"
)


def main():
    req = json.load(sys.stdin) if not sys.stdin.isatty() else {}
    candidate = {
        "id": "KQL014",
        "name": "UnboundedFacet",
        "shortDescription": "'facet' computes a per-column breakdown and can be expensive; scope or remove it.",
        "level": "warning",
        "weight": 2,
        "message": "'facet' computes a breakdown per column and is expensive; scope or remove it.",
        "analyzerBlock": ANALYZER_BLOCK,
        "sample": SAMPLE,
        "sampleSlug": "facet",
        "signature": req.get("signature", ""),
    }
    json.dump(candidate, sys.stdout, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
