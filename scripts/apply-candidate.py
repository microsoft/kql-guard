#!/usr/bin/env python3
"""Mechanically insert a drafted rule (scripts/suggest-rule.md candidate spec)
into the four template files. Deterministic and idempotent, mirroring
_set_weight.py: the AI drafts, this inserts, the gate validates.

Usage: apply-candidate.py <candidate.json> [--root DIR]
"""
import json
import os
import sys

# Unique anchors verified in the current source.
RULES_ANCHOR = "\n    };\n\n    private static readonly Dictionary<string, int> Index ="
ANALYZE_ANCHOR = "        return violations;\n    }\n\n    private static Expression BaseSource"
TESTS_ANCHOR = '\necho "----"'


def _insert_once(text, anchor, insertion, present):
    if present in text:
        return text, False          # idempotent: already applied
    if anchor not in text:
        raise SystemExit(f"apply-candidate: anchor not found: {anchor[:40]!r}")
    return text.replace(anchor, insertion + anchor, 1), True


def apply(candidate, root="."):
    cid, name = candidate["id"], candidate["name"]
    cost_path = os.path.join(root, "CostRules.cs")
    tests_path = os.path.join(root, "test", "run-tests.sh")
    slug = candidate["sampleSlug"]

    src = open(cost_path, encoding="utf-8").read()
    rule_line = (f'        new("{cid}", "{name}",\n'
                 f'            "{candidate["shortDescription"]}", "{candidate["level"]}", {int(candidate["weight"])}),')
    src, _ = _insert_once(src, RULES_ANCHOR, "\n" + rule_line, f'new("{cid}"')
    src, _ = _insert_once(src, ANALYZE_ANCHOR, candidate["analyzerBlock"] + "\n",
                          candidate["analyzerBlock"].strip().splitlines()[0].strip())
    open(cost_path, "w", encoding="utf-8").write(src)

    sample_path = os.path.join(root, "samples", "cost", slug + ".kql")
    os.makedirs(os.path.dirname(sample_path), exist_ok=True)
    if not os.path.exists(sample_path):
        open(sample_path, "w", encoding="utf-8").write(candidate["sample"])

    tests = open(tests_path, encoding="utf-8").read()
    assertion = f'\nassert_contains "{cid} {slug}" "{cid}" "$(RUN $S/{slug}.kql)"\n'
    tests, _ = _insert_once(tests, TESTS_ANCHOR, assertion, f'"{cid} {slug}"')
    open(tests_path, "w", encoding="utf-8").write(tests)
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.stderr.write("usage: apply-candidate.py <candidate.json> [--root DIR]\n")
        sys.exit(2)
    root = sys.argv[sys.argv.index("--root") + 1] if "--root" in sys.argv else "."
    sys.exit(apply(json.load(open(sys.argv[1])), root))
