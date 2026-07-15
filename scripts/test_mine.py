#!/usr/bin/env python3
"""Self-checks for mine.py. No framework: assert + exit code."""
import sys
import mine

# Two structurally identical queries (same signature) + one different.
FINDINGS = {
    "costScores": {"scratch/q1.kql": 1, "scratch/q2.kql": 1,
                   "scratch/q3.kql": 0, "scratch/q4.kql": 0},
    "findings": [{"file": "scratch/q1.kql", "rule": "KQL002"}],  # q1 already flagged
    "shapes": {
        "scratch/q1.kql": "A;B;contains;",   # cluster X (flagged member q1)
        "scratch/q2.kql": "A;B;contains;",   # cluster X (unflagged member q2)
        "scratch/q3.kql": "A;facet;",        # cluster Y, cheap, unflagged
        "scratch/q4.kql": "A;facet;",        # cluster Y
    },
}
MANIFEST = {
    "q1": {"durationMs": 50}, "q2": {"durationMs": 70},   # cluster X median 60
    "q3": {"durationMs": 5},  "q4": {"durationMs": 9},    # cluster Y median 7
}


def check(label, cond):
    print(("ok" if cond else "FAIL") + ": " + label)
    return 0 if cond else 1


def main():
    fails = 0
    clusters = mine.mine(FINDINGS, MANIFEST)

    # Clustering: two clusters, sizes 2 and 2.
    fails += check("two clusters", len(clusters) == 2)
    by_sig = {c["signature"]: c for c in clusters}
    fails += check("cluster X count 2", by_sig["A;B;contains;"]["count"] == 2)

    # Existing-finding correlation.
    fails += check("X withExistingFinding 1", by_sig["A;B;contains;"]["withExistingFinding"] == 1)
    fails += check("Y withExistingFinding 0", by_sig["A;facet;"]["withExistingFinding"] == 0)

    # Cost-ranked ordering: expensive cluster X first even though both recur equally.
    fails += check("X ranks above Y", clusters[0]["signature"] == "A;B;contains;")

    # Candidate selection: only unflagged clusters, cost-ranked, top-N.
    cands = mine.candidates(clusters, top_n=5)
    fails += check("one candidate (Y only)", len(cands) == 1 and cands[0]["signature"] == "A;facet;")

    # top_n limit.
    fails += check("top_n caps clusters", len(mine.mine(FINDINGS, MANIFEST, top_n=1)) == 1)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
