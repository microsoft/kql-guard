#!/usr/bin/env python3
"""Cluster query shapes and rank recurring, unflagged, high-cost shapes as
new-rule candidates.

Inputs:
  findings.json  kql-guard <corpus> --format json --shapes:
                 {"findings":[{"file","rule",...}],
                  "costScores":{file:int},           # every analyzed file
                  "shapes":{file: signature}}        # parseable files only
  manifest.json  per-query cost keyed by <id> (scripts/manifest.schema.md)

Emits clusters and candidates. Reads no query text; the shape signature is
already abstracted (operator/built-in kinds only). Output carries signatures,
counts, and aggregate cost — never query text.
"""
import json
import statistics
import sys

from calibrate import load, qid   # reuse Plan 1 helpers


def mine(findings_doc, manifest, rank_metric="durationMs", top_n=None):
    """Group files by shape signature; per cluster report count, how many
    members already trigger a rule, and the median real cost. Ranked by median
    cost desc (clusters with no cost data sort last)."""
    flagged = {qid(f["file"]) for f in findings_doc.get("findings", [])}
    groups = {}
    for file, sig in (findings_doc.get("shapes") or {}).items():
        groups.setdefault(sig, []).append(file)

    clusters = []
    for sig, members in groups.items():
        durations = [manifest[qid(m)][rank_metric] for m in members
                     if qid(m) in manifest and manifest[qid(m)].get(rank_metric) is not None]
        clusters.append({
            "signature": sig,
            "count": len(members),
            "withExistingFinding": sum(1 for m in members if qid(m) in flagged),
            "medianDurationMs": statistics.median(durations) if durations else None,
            "sampleFile": members[0],
        })
    # -1 sentinel sorts None-cost clusters last; ties break by higher count.
    clusters.sort(key=lambda c: (c["medianDurationMs"] if c["medianDurationMs"] is not None else -1,
                                 c["count"]), reverse=True)
    return clusters[:top_n] if top_n else clusters


def candidates(clusters, top_n=5):
    """New-rule candidates: recurring shapes the current ruleset never flags,
    highest real cost first."""
    unflagged = [c for c in clusters if c["withExistingFinding"] == 0]
    return unflagged[:top_n]


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: mine.py <findings.json> <manifest.json> [--top N] [--candidates-json OUT]\n")
        return 2
    findings_doc, manifest = load(argv[1]), load(argv[2])
    top_n = int(argv[argv.index("--top") + 1]) if "--top" in argv else 5
    clusters = mine(findings_doc, manifest)
    cands = candidates(clusters, top_n)
    if "--candidates-json" in argv:
        with open(argv[argv.index("--candidates-json") + 1], "w") as f:
            json.dump(cands, f, indent=2, sort_keys=True)
    # Human-readable summary: aggregate only, no query text.
    print(f"clusters={len(clusters)} candidates={len(cands)} (unflagged, cost-ranked)")
    for c in cands:
        med = "—" if c["medianDurationMs"] is None else f"{c['medianDurationMs']:.0f}ms"
        print(f"- count={c['count']} median={med} sig={c['signature'][:60]}...")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
