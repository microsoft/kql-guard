#!/usr/bin/env python3
"""Correlate kql-guard findings with real QueryCompletion execution cost.

Inputs:
  findings.json  kql-guard <corpus> --format json output:
                 {"findings":[{"file","rule","costWeight",...}],
                  "costScores":{file: score}}   # costScores covers EVERY analyzed file
  manifest.json  per-query cost keyed by <id> (see scripts/manifest.schema.md)

Output: an aggregate per-rule cost report. Reads no query text; emits only
rule IDs and aggregate numbers.
"""
import json, math, statistics, sys

METRICS = ["durationMs", "cpuMs", "memoryPeakBytes", "scannedRows"]


def load(path):
    with open(path) as f:
        return json.load(f)


def qid(file_path):
    """scratch/<id>.kql -> <id>. The join key between findings and manifest."""
    base = file_path.replace("\\", "/").rsplit("/", 1)[-1]
    return base[:-4] if base.endswith(".kql") else base


def pctl(values, p):
    """p-th percentile (0..100), nearest-rank. [] -> None."""
    if not values:
        return None
    s = sorted(values)
    rank = max(1, math.ceil(p / 100 * len(s)))
    return s[rank - 1]


def aggregate(ids, manifest, metric):
    vals = [manifest[i][metric] for i in ids
            if i in manifest and manifest[i].get(metric) is not None]
    if not vals:
        return None
    return {"n": len(vals), "median": statistics.median(vals), "p95": pctl(vals, 95)}


def correlate(findings_doc, manifest):
    universe = {qid(f) for f in findings_doc.get("costScores", {})}
    rule_ids, flagged = {}, set()
    for fnd in findings_doc.get("findings", []):
        i = qid(fnd["file"])
        rule_ids.setdefault(fnd["rule"], set()).add(i)
        flagged.add(i)
    # Baseline = analyzed queries with no finding that also completed. A Failed
    # query is not a clean "unflagged good query", so exclude it here.
    baseline_ids = {i for i in (universe - flagged)
                    if manifest.get(i, {}).get("state") != "Failed"}
    per_rule = {}
    for rule, ids in rule_ids.items():
        entry = {m: aggregate(ids, manifest, m) for m in METRICS}
        entry["count"] = len(ids)
        per_rule[rule] = entry
    baseline = {m: aggregate(baseline_ids, manifest, m) for m in METRICS}
    baseline["count"] = len(baseline_ids)
    return per_rule, baseline


def weight_disagreement(findings_doc, per_rule, rank_metric="durationMs", threshold=2):
    """Rank rules by measured median cost vs. their declared CostWeight; flag
    rules whose two ranks disagree by >= threshold. Rank 0 = most expensive /
    highest weight, so a positive (costRank - weightRank) means the rule is
    weighted higher than its measured cost -> down-weight."""
    weight = {}
    for fnd in findings_doc.get("findings", []):
        weight.setdefault(fnd["rule"], fnd.get("costWeight", 0))
    rules = [r for r in per_rule
             if weight.get(r, 0) > 0 and per_rule[r].get(rank_metric)]
    by_cost = sorted(rules, key=lambda r: per_rule[r][rank_metric]["median"], reverse=True)
    by_weight = sorted(rules, key=lambda r: weight[r], reverse=True)
    cost_rank = {r: i for i, r in enumerate(by_cost)}
    weight_rank = {r: i for i, r in enumerate(by_weight)}
    flags = []
    for r in rules:
        diff = cost_rank[r] - weight_rank[r]
        if abs(diff) >= threshold:
            flags.append({
                "rule": r,
                "weight": weight[r],
                "medianDurationMs": per_rule[r][rank_metric]["median"],
                "costRank": cost_rank[r],
                "weightRank": weight_rank[r],
                "suggest": "down-weight" if diff > 0 else "up-weight",
            })
    return sorted(flags, key=lambda f: f["rule"])


def failure_catch(findings_doc, manifest):
    """Of the queries ADX reports as Failed, how many could kql-guard catch
    offline? A query is 'catchable' when kql-guard produced a KQL001 syntax
    finding for it. Semantic failures (SEM/'Semantic error') need a schema
    kql-guard does not have offline -> schema-dependent. Anything else Failed
    without a finding is 'missed'. Returns counts only; failureReason strings
    are classified here but never emitted (they can embed identifiers)."""
    syntactic_caught = {qid(f["file"]) for f in findings_doc.get("findings", [])
                        if f["rule"] == "KQL001"}
    failed = {i: m for i, m in manifest.items() if m.get("state") == "Failed"}
    catchable = schema_dependent = missed = 0
    for i, m in failed.items():
        reason = m.get("failureReason") or ""
        is_semantic = "Semantic error" in reason or "SEM" in reason
        if i in syntactic_caught:
            catchable += 1
        elif is_semantic:
            schema_dependent += 1
        else:
            missed += 1
    return {"failed": len(failed), "catchable": catchable,
            "schemaDependent": schema_dependent, "missed": missed}


def _fmt(agg):
    if not agg:
        return "—"
    return f"n={agg['n']} med={agg['median']:.0f} p95={agg['p95']:.0f}"


def render_markdown(report):
    lines = ["## kql-guard calibration (existing-rule frequency + real cost)", "",
             "| Rule | Fires | Duration ms | Scanned rows | CPU ms | Peak mem |",
             "|------|------:|-------------|--------------|--------|----------|"]
    for rule in sorted(report["perRule"]):
        a = report["perRule"][rule]
        lines.append(f"| {rule} | {a['count']} | {_fmt(a['durationMs'])} | "
                     f"{_fmt(a['scannedRows'])} | {_fmt(a['cpuMs'])} | {_fmt(a['memoryPeakBytes'])} |")
    b = report["baseline"]
    lines.append(f"| _baseline (no findings)_ | {b['count']} | {_fmt(b['durationMs'])} | "
                 f"{_fmt(b['scannedRows'])} | {_fmt(b['cpuMs'])} | {_fmt(b['memoryPeakBytes'])} |")

    lines += ["", "### Weight-review candidates (human decides; nothing auto-applied)"]
    reviews = report.get("weightReview") or []
    if reviews:
        for f in reviews:
            lines.append(f"- **{f['rule']}** weight={f['weight']} "
                         f"median={f['medianDurationMs']:.0f}ms "
                         f"costRank={f['costRank']} weightRank={f['weightRank']} "
                         f"→ suggest {f['suggest']}")
    else:
        lines.append("- none")

    fc = report.get("failureCatch") or {}
    if fc:
        lines += ["", "### Failure-catch (of real Failed queries)",
                  f"- failed={fc['failed']} catchable(syntax)={fc['catchable']} "
                  f"schema-dependent(offline-blind)={fc['schemaDependent']} missed={fc['missed']}"]
    return "\n".join(lines)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: calibrate.py <findings.json> <manifest.json> [--json OUT]\n")
        return 2
    findings_doc, manifest = load(argv[1]), load(argv[2])
    per_rule, baseline = correlate(findings_doc, manifest)
    report = {"perRule": per_rule, "baseline": baseline,
              "weightReview": weight_disagreement(findings_doc, per_rule),
              "failureCatch": failure_catch(findings_doc, manifest)}
    if "--json" in argv:
        with open(argv[argv.index("--json") + 1], "w") as f:
            json.dump(report, f, indent=2, sort_keys=True)
    print(render_markdown(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
