#!/usr/bin/env python3
"""Self-check for apply-candidate.py: it inserts a drafted rule into a copy of
the four template files without touching anything else."""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def main():
    cand = json.loads(subprocess.check_output(
        ["python3", os.path.join(HERE, "mock-suggester.py")],
        input=json.dumps({"signature": "A;facet;", "count": 4, "medianDurationMs": 900}).encode()))
    work = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(work, "samples", "cost"))
        os.makedirs(os.path.join(work, "test"))
        shutil.copy(os.path.join(ROOT, "CostRules.cs"), os.path.join(work, "CostRules.cs"))
        shutil.copy(os.path.join(ROOT, "test", "run-tests.sh"), os.path.join(work, "test", "run-tests.sh"))
        cj = os.path.join(work, "candidate.json")
        json.dump(cand, open(cj, "w"))
        rc = subprocess.call(["python3", os.path.join(HERE, "apply-candidate.py"), cj, "--root", work])
        assert rc == 0, "apply returned nonzero"

        cs = open(os.path.join(work, "CostRules.cs")).read()
        assert f'new("{cand["id"]}"' in cs, "RuleInfo not inserted"
        assert cand["analyzerBlock"].strip().splitlines()[0].strip() in cs, "analyzer block not inserted"
        sample = os.path.join(work, "samples", "cost", cand["sampleSlug"] + ".kql")
        assert os.path.exists(sample), "sample not written"
        rt = open(os.path.join(work, "test", "run-tests.sh")).read()
        assert cand["id"] in rt and cand["sampleSlug"] in rt, "assertion not appended"
        # Idempotent: re-applying is a no-op (already present).
        rc2 = subprocess.call(["python3", os.path.join(HERE, "apply-candidate.py"), cj, "--root", work])
        assert rc2 == 0 and open(os.path.join(work, "CostRules.cs")).read().count(f'new("{cand["id"]}"') == 1, \
            "not idempotent"
        print("ok: apply-candidate inserts rule into the four template files")
        return 0
    except AssertionError as e:
        print("FAIL:", e)
        return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
