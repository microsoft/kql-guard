#!/usr/bin/env python3
"""Self-check for calibrate.py. No framework: plain asserts, run directly."""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import calibrate

HERE = os.path.dirname(__file__)
FIX = os.path.join(HERE, "..", "test", "fixtures", "calib")


def load(name):
    with open(os.path.join(FIX, name)) as f:
        return json.load(f)


def test_qid():
    assert calibrate.qid("scratch/q1.kql") == "q1"
    assert calibrate.qid("a/b/deadbeef.kql") == "deadbeef"
    assert calibrate.qid("q9") == "q9"


def test_correlate_baseline_and_counts():
    findings, manifest = load("findings.json"), load("manifest.json")
    per_rule, baseline = calibrate.correlate(findings, manifest)
    # Two cost rules fired once each; KQL001 also present.
    assert per_rule["KQL003"]["count"] == 1
    assert per_rule["KQL002"]["count"] == 1
    # KQL002's one query (q2) is the expensive one.
    assert per_rule["KQL002"]["durationMs"]["median"] == 9000.0
    assert per_rule["KQL003"]["durationMs"]["median"] == 10.0
    # Baseline = analyzed queries with no finding AND not Failed => {q4}.
    assert baseline["count"] == 1
    assert baseline["durationMs"]["median"] == 2.0


def test_render_has_rules_and_baseline():
    findings, manifest = load("findings.json"), load("manifest.json")
    per_rule, baseline = calibrate.correlate(findings, manifest)
    md = calibrate.render_markdown(
        {"perRule": per_rule, "baseline": baseline, "weightReview": [], "failureCatch": {}})
    assert "KQL002" in md and "KQL003" in md
    assert "baseline" in md


if __name__ == "__main__":
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn(); print(f"ok: {name}"); n += 1
    print(f"ALL PASS ({n})")
