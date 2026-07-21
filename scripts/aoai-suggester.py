#!/usr/bin/env python3
"""Azure OpenAI new-rule suggester (scripts/suggest-rule.md contract).

Drop-in for SUGGESTER_CMD on the runner: reads a masked shape signature on
stdin, asks an in-tenant Azure OpenAI deployment to draft a cost rule, and emits
a validated candidate on stdout. Fail-closed: any error (auth, network,
malformed model output, schema/semantic miss) prints a reason to stderr, exits
nonzero, and writes NOTHING to stdout.

Boundary: consumes ONLY stdin. The signature is already public-safe (it appears
verbatim in PR bodies). The confidential real-text upgrade changes the mining
*input* (real Text on stdin) + the endpoint (private + Zero-Data-Retention), not
this adapter.

Env:
  KUSKUS_AOAI_ENDPOINT     https://<name>.openai.azure.com
  KUSKUS_AOAI_DEPLOYMENT   the deployment name (e.g. gpt-5-mini)
  KUSKUS_AOAI_API_VERSION  data-plane api-version; must support json_schema
                           structured outputs + the deployed model family
                           (default 2025-04-01-preview)
  KUSKUS_MI_CLIENT_ID      user-assigned MI client id (optional; omit for the
                           VM's default identity)

Deps: Python stdlib only (urllib). No openai / azure-identity SDK.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

IMDS_TOKEN_URL = "http://169.254.169.254/metadata/identity/oauth2/token"
AOAI_SCOPE = "https://cognitiveservices.azure.com"
DEFAULT_API_VERSION = "2025-04-01-preview"
LEVELS = {"warning", "error"}

# Two existing rules as few-shot exemplars of the required analyzer-block shape
# (single GetDescendants + Make, mirroring CostRules.cs KQL002/004/005/007).
# Inlined so the adapter has no parse dependency on the C# source.
FEW_SHOT = [
    {
        "name": "UnboundedSort",
        "level": "warning",
        "weight": 2,
        "analyzerBlock": (
            "        foreach (var sort in root.GetDescendants<SortOperator>())\n"
            "        {\n"
            "            violations.Add(Make(code, filePath, sort.TextStart, \"KQLNNN\",\n"
            "                \"'sort' without a following 'take'/'top' orders the whole result; add a bound.\"));\n"
            "        }\n"
        ),
        "sample": "// unbounded sort\nSyntheticEvents\n| sort by StartTime desc\n",
    },
    {
        "name": "UnboundedMvExpand",
        "level": "warning",
        "weight": 2,
        "analyzerBlock": (
            "        foreach (var mv in root.GetDescendants<MvExpandOperator>())\n"
            "        {\n"
            "            violations.Add(Make(code, filePath, mv.TextStart, \"KQLNNN\",\n"
            "                \"'mv-expand' without 'limit' can explode row count; add a bound.\"));\n"
            "        }\n"
        ),
        "sample": "// unbounded mv-expand\nSyntheticEvents\n| mv-expand Tags\n",
    },
]


def next_free_id(costrules_text):
    """Next unused id in the cost band KQL0NN (001-013 -> KQL014). The 1NN
    semantic band (KQL101 UnknownColumnOrTable) is a different registry and is
    excluded, so the model can never collide with it either."""
    nums = [int(m) for m in re.findall(r'new\("KQL(0\d\d)"', costrules_text)]
    return "KQL%03d" % ((max(nums) + 1) if nums else 1)


def build_messages(inp, assigned_id):
    few_shot = "\n".join(json.dumps(x) for x in FEW_SHOT)
    system = (
        "You draft ONE kql-guard cost-analysis rule for a recurring, currently "
        "unflagged, expensive KQL shape. kql-guard is an offline static analyzer "
        "over the Kusto.Language AST. Return ONLY the JSON fields in the schema. "
        "Hard constraints:\n"
        f"- The rule id is FIXED to {assigned_id}. Use it verbatim wherever an id "
        "appears (you do not choose it).\n"
        "- analyzerBlock MUST be exactly one C# foreach of the form "
        "`foreach (var x in root.GetDescendants<SomeOperator>()) { "
        "violations.Add(Make(code, filePath, x.TextStart, \"" + assigned_id +
        "\", \"<message>\")); }`, using a real Kusto.Language syntax node type "
        "for the most expensive structural feature of the shape.\n"
        "- sample MUST be synthetic KQL: invented table and column names, NO real "
        "identifiers or literal values, and it MUST trigger the rule.\n"
        "- sampleSlug MUST be kebab-case (lowercase letters, digits, hyphens).\n"
        "- level MUST be 'warning' or 'error'; weight MUST be a small positive "
        "integer.\n"
        "Examples of good rules (analyzerBlock id shown as KQLNNN for the shape "
        "only):\n" + few_shot
    )
    user = (
        "Draft a rule for this abstracted shape. Only structural node kinds are "
        "given; identifiers and literals are masked. Base the detector on the "
        "most expensive structural feature you can identify.\n"
        f"signature: {inp.get('signature', '')}\n"
        f"recurrence_count: {inp.get('count')}\n"
        f"median_duration_ms: {inp.get('medianDurationMs')}\n"
    )
    return [{"role": "system", "content": system},
            {"role": "user", "content": user}]


CANDIDATE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["name", "shortDescription", "level", "weight", "message",
                 "analyzerBlock", "sample", "sampleSlug"],
    "properties": {
        "name": {"type": "string"},
        "shortDescription": {"type": "string"},
        "level": {"type": "string", "enum": ["warning", "error"]},
        "weight": {"type": "integer"},
        "message": {"type": "string"},
        "analyzerBlock": {"type": "string"},
        "sample": {"type": "string"},
        "sampleSlug": {"type": "string"},
    },
}


def _imds_token():
    """User-assigned (or default) MI token for the AOAI data plane via IMDS."""
    cid = os.environ.get("KUSKUS_MI_CLIENT_ID", "")
    url = (f"{IMDS_TOKEN_URL}?api-version=2018-02-01&resource={AOAI_SCOPE}"
           + (f"&client_id={cid}" if cid else ""))
    req = urllib.request.Request(url, headers={"Metadata": "true"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)["access_token"]


def _call_aoai(messages):
    """POST chat/completions with json_schema structured output; return the
    parsed model dict. Raises on HTTP error, refusal, or unparseable content."""
    endpoint = os.environ["KUSKUS_AOAI_ENDPOINT"].rstrip("/")
    deployment = os.environ["KUSKUS_AOAI_DEPLOYMENT"]
    api = os.environ.get("KUSKUS_AOAI_API_VERSION", DEFAULT_API_VERSION)
    url = (f"{endpoint}/openai/deployments/{deployment}/chat/completions"
           f"?api-version={api}")
    body = json.dumps({
        "messages": messages,
        # ponytail: no temperature — the GPT-5/reasoning families reject a
        # non-default temperature with a 400. Output is schema-constrained anyway.
        "response_format": {
            "type": "json_schema",
            "json_schema": {
                "name": "kql_rule_candidate",
                "strict": True,
                "schema": CANDIDATE_SCHEMA,
            },
        },
    }).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {_imds_token()}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = json.load(r)
    except urllib.error.HTTPError as e:
        # Surface Azure's actual complaint (unsupported param, api-version, role,
        # ...) instead of a bare "HTTP Error 400". Still fail-closed: main()
        # catches this, logs it, and the mining run skips the draft.
        raise RuntimeError("AOAI %s: %s" % (
            e.code, e.read().decode("utf-8", "replace")[:800])) from None
    msg = raw["choices"][0]["message"]
    if msg.get("refusal"):
        raise ValueError("model refused: " + str(msg["refusal"]))
    return json.loads(msg["content"])


def merge_and_validate(model_out, inp, assigned_id, costrules_text, samples_dir):
    """Fail-closed: force the mechanical id, verify every field, and check the
    analyzerBlock template + id + no id/slug collisions. Raises ValueError on any
    miss. Echoes the (already-abstracted) aggregates for PR fingerprinting."""
    c = dict(model_out)
    c["id"] = assigned_id  # ours, never the model's
    for k in ("name", "shortDescription", "level", "weight", "message",
              "analyzerBlock", "sample", "sampleSlug"):
        if k not in c or c[k] in ("", None):
            raise ValueError("missing field: " + k)
    if c["level"] not in LEVELS:
        raise ValueError("bad level: %r" % (c["level"],))
    if not isinstance(c["weight"], int) or isinstance(c["weight"], bool) or c["weight"] < 1:  # bool is an int subclass; reject JSON true/false
        raise ValueError("bad weight: %r" % (c["weight"],))
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", c["sampleSlug"]):
        raise ValueError("bad sampleSlug: %r" % (c["sampleSlug"],))
    if os.path.exists(os.path.join(samples_dir, c["sampleSlug"] + ".kql")):
        raise ValueError("sampleSlug collides with an existing sample: " + c["sampleSlug"])
    block = c["analyzerBlock"]
    if ("GetDescendants<" not in block or "violations.Add(Make(" not in block
            or ('"%s"' % assigned_id) not in block):
        raise ValueError("analyzerBlock does not match the required template / id")
    if ('new("%s"' % assigned_id) in costrules_text:
        raise ValueError("id already present in CostRules.cs: " + assigned_id)
    c["signature"] = inp.get("signature", "")
    c["count"] = inp.get("count", 0)
    c["medianDurationMs"] = inp.get("medianDurationMs")
    return c


def main():
    try:
        inp = json.load(sys.stdin)
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        costrules = open(os.path.join(repo, "CostRules.cs"), encoding="utf-8").read()
        samples_dir = os.path.join(repo, "samples", "cost")
        assigned_id = next_free_id(costrules)
        model_out = _call_aoai(build_messages(inp, assigned_id))
        candidate = merge_and_validate(model_out, inp, assigned_id, costrules, samples_dir)
    except Exception as e:  # fail-closed: nothing on stdout
        sys.stderr.write("aoai-suggester: %s\n" % e)
        return 1
    json.dump(candidate, sys.stdout, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
