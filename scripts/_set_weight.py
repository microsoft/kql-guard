#!/usr/bin/env python3
"""Set exactly one rule's CostWeight in CostRules.cs. Deterministic and keyed
by rule id, so weight tuning stays a one-number mechanical change.

Usage: _set_weight.py <CostRules.cs> <ruleId> <newWeight>
"""
import re, sys


def set_weight(path, rule, new_weight):
    src = open(path, encoding="utf-8").read()
    # Match: new("KQL003", "Name", <newlines/desc> "warning"|"error", <int>)
    # Non-greedy up to the first quoted level token, so the description (which
    # may contain the word error/warning unquoted) is skipped safely.
    pattern = re.compile(
        r'(new\("' + re.escape(rule) + r'",.*?"(?:error|warning)",\s*)\d+(\s*\))',
        re.S)
    new_src, n = pattern.subn(lambda m: m.group(1) + str(new_weight) + m.group(2),
                              src, count=1)
    if n != 1:
        sys.stderr.write(f"_set_weight: expected exactly one {rule} entry, matched {n}\n")
        return 1
    open(path, "w", encoding="utf-8").write(new_src)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.stderr.write("usage: _set_weight.py <CostRules.cs> <ruleId> <newWeight>\n")
        sys.exit(2)
    sys.exit(set_weight(sys.argv[1], sys.argv[2], int(sys.argv[3])))
