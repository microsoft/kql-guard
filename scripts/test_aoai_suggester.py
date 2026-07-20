#!/usr/bin/env python3
"""Network-free self-test for the AOAI new-rule suggester.

Stubs the two HTTP seams (_imds_token, _call_aoai) so nothing touches IMDS or
Azure OpenAI. Asserts: mechanical id (never the model's), aggregate echo,
fail-closed on every malformed/invalid model output, and a full offline pass
through main().
"""
import io
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def _load():
    spec = importlib.util.spec_from_file_location(
        "aoai_suggester", os.path.join(HERE, "aoai-suggester.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sug = _load()
fails = 0


def check(cond, msg):
    global fails
    print(("ok: " if cond else "FAIL: ") + msg)
    if not cond:
        fails += 1


# A synthetic CostRules.cs fixture: cost band KQL001..KQL013 + semantic KQL101.
FIX_RULES = "\n".join(
    'new("KQL%03d", "Rule%d", "desc", "warning", 1),' % (n, n) for n in range(1, 14)
) + '\nnew("KQL101", "UnknownColumnOrTable", "desc", "error", 2),'

INP = {"signature": "Query;WhereOperator;FacetOperator;", "count": 5, "medianDurationMs": 4050.0}


def good_model_out(rule_id):
    return {
        "name": "UnboundedFacet",
        "shortDescription": "'facet' computes a per-column breakdown and can be expensive.",
        "level": "warning",
        "weight": 2,
        "message": "'facet' is expensive; scope or remove it.",
        "analyzerBlock": (
            "        foreach (var facet in root.GetDescendants<FacetOperator>())\n"
            "        {\n"
            "            violations.Add(Make(code, filePath, facet.TextStart, \"%s\",\n"
            "                \"'facet' is expensive; scope or remove it.\"));\n"
            "        }\n" % rule_id
        ),
        "sample": "// sample\nSyntheticEvents\n| facet by Category\n",
        "sampleSlug": "unbounded-facet-demo",
    }


# --- next_free_id: cost band max+1, ignoring the 1NN semantic band ---
check(sug.next_free_id(FIX_RULES) == "KQL014", "next_free_id -> KQL014 (ignores KQL101)")
check(sug.next_free_id('new("KQL101", "X", "d", "error", 2),') == "KQL001",
      "next_free_id -> KQL001 when the cost band is empty")

# --- merge_and_validate: happy path sets id + echoes aggregates ---
with tempfile.TemporaryDirectory() as empty_samples:
    c = sug.merge_and_validate(good_model_out("KQL014"), INP, "KQL014", FIX_RULES, empty_samples)
    check(c["id"] == "KQL014", "merge forces the mechanical id")
    check(c["signature"] == INP["signature"] and c["count"] == 5
          and c["medianDurationMs"] == 4050.0, "merge echoes signature/count/median")

    # Model tries to pick a DIFFERENT id in its analyzerBlock -> rejected
    # (analyzerBlock must reference the assigned id).
    bad_id = good_model_out("KQL099")
    try:
        sug.merge_and_validate(bad_id, INP, "KQL014", FIX_RULES, empty_samples)
        check(False, "analyzerBlock with the wrong id is rejected")
    except ValueError:
        check(True, "analyzerBlock with the wrong id is rejected")

    # bad level
    try:
        sug.merge_and_validate({**good_model_out("KQL014"), "level": "info"},
                               INP, "KQL014", FIX_RULES, empty_samples)
        check(False, "level not in {warning,error} is rejected")
    except ValueError:
        check(True, "level not in {warning,error} is rejected")

    # missing required field
    try:
        m = good_model_out("KQL014"); del m["sample"]
        sug.merge_and_validate(m, INP, "KQL014", FIX_RULES, empty_samples)
        check(False, "missing required field is rejected")
    except ValueError:
        check(True, "missing required field is rejected")

    # non-template analyzerBlock (no GetDescendants / Make)
    try:
        sug.merge_and_validate({**good_model_out("KQL014"),
                                "analyzerBlock": 'return "KQL014";'},
                               INP, "KQL014", FIX_RULES, empty_samples)
        check(False, "non-template analyzerBlock is rejected")
    except ValueError:
        check(True, "non-template analyzerBlock is rejected")

# --- sampleSlug that collides with an existing sample is rejected ---
with tempfile.TemporaryDirectory() as samples:
    open(os.path.join(samples, "unbounded-facet-demo.kql"), "w").close()
    try:
        sug.merge_and_validate(good_model_out("KQL014"), INP, "KQL014", FIX_RULES, samples)
        check(False, "colliding sampleSlug is rejected")
    except ValueError:
        check(True, "colliding sampleSlug is rejected")


# --- main(): full offline pass through the real CostRules.cs ---
def run_main(stdin_text, call_aoai_impl):
    saved_in, saved_out = sys.stdin, sys.stdout
    saved_token, saved_call = sug._imds_token, sug._call_aoai
    sys.stdin = io.StringIO(stdin_text)
    sys.stdout = io.StringIO()
    sug._imds_token = lambda: "faketoken-not-used"
    sug._call_aoai = call_aoai_impl
    try:
        rc = sug.main()
        return rc, sys.stdout.getvalue()
    finally:
        sys.stdin, sys.stdout = saved_in, saved_out
        sug._imds_token, sug._call_aoai = saved_token, saved_call


# The real CostRules.cs decides the id; compute it the same way the adapter does
# so this test is robust to future rule additions.
expected_id = sug.next_free_id(open(os.path.join(REPO, "CostRules.cs"), encoding="utf-8").read())

rc, out = run_main(json.dumps(INP), lambda messages: good_model_out(expected_id))
check(rc == 0, "main() returns 0 on a valid model response")
emitted = json.loads(out) if out.strip() else {}
check(emitted.get("id") == expected_id, "main() emits the mechanical id (%s)" % expected_id)
check(emitted.get("signature") == INP["signature"], "main() echoes the signature")

# malformed: _call_aoai raises (e.g. unparseable JSON / model refusal)
def boom(messages):
    raise ValueError("model returned non-JSON content")

rc, out = run_main(json.dumps(INP), boom)
check(rc == 1 and out.strip() == "", "main() fails closed on a call error (rc=1, empty stdout)")

# malformed: model omits a field -> merge rejects -> fail closed
def missing_field(messages):
    m = good_model_out(expected_id); del m["weight"]; return m

rc, out = run_main(json.dumps(INP), missing_field)
check(rc == 1 and out.strip() == "", "main() fails closed on a missing field (rc=1, empty stdout)")

# --- _call_aoai builds a correct authenticated request (network-free) ---
import urllib.request as _urlreq


class _FakeResp:
    def __init__(self, payload):
        self._b = json.dumps(payload).encode()

    def read(self, *a):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _call_aoai_capture(model_payload):
    captured = {}

    def fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        captured["headers"] = {k.lower(): v for k, v in req.header_items()}
        captured["body"] = req.data
        return _FakeResp({"choices": [{"message": {"content": json.dumps(model_payload)}}]})

    keys = ("KUSKUS_AOAI_ENDPOINT", "KUSKUS_AOAI_DEPLOYMENT", "KUSKUS_AOAI_API_VERSION")
    saved_env = {k: os.environ.get(k) for k in keys}
    saved_token, saved_open = sug._imds_token, _urlreq.urlopen
    sug._imds_token = lambda: "tok-123"
    _urlreq.urlopen = fake_urlopen
    os.environ["KUSKUS_AOAI_ENDPOINT"] = "https://ep.openai.azure.com/"
    os.environ["KUSKUS_AOAI_DEPLOYMENT"] = "gpt-4o"
    os.environ["KUSKUS_AOAI_API_VERSION"] = "2024-10-21"
    try:
        return sug._call_aoai([{"role": "user", "content": "hi"}]), captured
    finally:
        sug._imds_token = saved_token
        _urlreq.urlopen = saved_open
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


_out, _cap = _call_aoai_capture(good_model_out("KQL014"))
check(_cap["headers"].get("authorization") == "Bearer tok-123",
      "_call_aoai sends the IMDS token as a Bearer header")
check("ep.openai.azure.com" in _cap["url"] and "gpt-4o" in _cap["url"]
      and "api-version=2024-10-21" in _cap["url"], "_call_aoai builds the URL from env")
check(b'"json_schema"' in _cap["body"], "_call_aoai requests json_schema structured output")
check(_out["name"] == "UnboundedFacet", "_call_aoai extracts the model content dict")


def _call_aoai_refusal():
    def fake_urlopen(req, timeout=None):
        return _FakeResp({"choices": [{"message": {"refusal": "no"}}]})

    saved_token, saved_open = sug._imds_token, _urlreq.urlopen
    sug._imds_token = lambda: "tok"
    _urlreq.urlopen = fake_urlopen
    os.environ["KUSKUS_AOAI_ENDPOINT"] = "https://ep.openai.azure.com/"
    os.environ["KUSKUS_AOAI_DEPLOYMENT"] = "gpt-4o"
    try:
        sug._call_aoai([{"role": "user", "content": "hi"}])
        return False
    except ValueError:
        return True
    finally:
        sug._imds_token = saved_token
        _urlreq.urlopen = saved_open


check(_call_aoai_refusal(), "_call_aoai raises on a model refusal")

print("ALL PASS" if fails == 0 else "%d FAILED" % fails)
sys.exit(0 if fails == 0 else 1)
