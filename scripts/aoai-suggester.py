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

# The closed set of concrete Kusto.Language 12.4.0 syntax node types a cost rule
# may target: every *Operator + *Expression SyntaxElement subtype. The model must
# pick GetDescendants<T> from THIS list. Left unconstrained it invents plausible
# but nonexistent names (observed: "InCsExpression" for the `in` operator, which
# is really "InExpression") that fail the C# build three gates downstream.
# Regenerate on a Kusto.Language bump: load the pinned Kusto.Language.dll and take
# every public non-abstract type where SyntaxElement.IsAssignableFrom(t) and the
# name ends with "Operator" or "Expression".
NODE_TYPES = (
    "AsOperator", "AssertSchemaOperator", "AtExpression",
    "BadQueryOperator", "BetweenExpression", "BinaryExpression",
    "BracketedExpression", "CompoundNamedExpression",
    "CompoundStringLiteralExpression", "ConsumeOperator",
    "ContextualDataTableExpression", "CountOperator", "DataScopeExpression",
    "DataTableExpression", "DistinctOperator", "DynamicExpression",
    "ElementExpression", "EvaluateOperator", "ExecuteAndCacheOperator",
    "ExtendOperator", "ExternalDataExpression", "FacetOperator",
    "FilterOperator", "FindOperator", "ForkExpression", "ForkOperator",
    "FunctionCallExpression", "GetSchemaOperator",
    "GraphMarkComponentsOperator", "GraphMatchOperator",
    "GraphShortestPathsOperator", "GraphToTableOperator",
    "GraphWhereEdgesOperator", "GraphWhereNodesOperator",
    "HasAllExpression", "HasAnyExpression", "InExpression",
    "InlineExternalTableExpression", "InvokeOperator", "JoinOperator",
    "JsonArrayExpression", "JsonObjectExpression", "LiteralExpression",
    "LookupOperator", "MacroExpandOperator", "MakeGraphOperator",
    "MakeSeriesExpression", "MakeSeriesOperator", "MaterializeExpression",
    "MaterializedViewCombineExpression", "MvApplyExpression",
    "MvApplyOperator", "MvApplySubqueryExpression", "MvExpandExpression",
    "MvExpandOperator", "OrderedExpression", "PackExpression",
    "ParenthesizedExpression", "ParseKvOperator", "ParseOperator",
    "ParseWhereOperator", "PartitionByOperator", "PartitionOperator",
    "PathExpression", "PipeExpression", "PrefixUnaryExpression",
    "PrimitiveTypeExpression", "PrintOperator", "ProjectAwayOperator",
    "ProjectByNamesOperator", "ProjectKeepOperator", "ProjectOperator",
    "ProjectRenameOperator", "ProjectReorderOperator", "RangeOperator",
    "ReduceByOperator", "RenderOperator", "SampleDistinctOperator",
    "SampleOperator", "ScanOperator", "SchemaTypeExpression",
    "SearchOperator", "SerializeOperator", "SimpleNamedExpression",
    "SortOperator", "StarExpression", "SummarizeOperator", "TakeOperator",
    "ToScalarExpression", "ToTableExpression", "TopHittersOperator",
    "TopNestedOperator", "TopOperator", "TypeOfLiteralExpression",
    "UnionOperator",
)

# Two existing rules as few-shot exemplars of the required analyzer-block shape
# (single GetDescendants + Make, mirroring CostRules.cs KQL002/004/005/007).
# Inlined so the adapter has no parse dependency on the C# source.
FEW_SHOT = [
    {
        "name": "UnboundedDistinct",
        "level": "warning",
        "weight": 2,
        "analyzerBlock": (
            "        foreach (var x in root.GetDescendants<DistinctOperator>())\n"
            "        {\n"
            "            if (root.GetDescendants<TakeOperator>().Count == 0)\n"
            "            {\n"
            "                violations.Add(Make(code, filePath, x.TextStart, \"KQLNNN\",\n"
            "                    \"'distinct' over an unbounded input scans every row; add a 'take'/'top' bound or pre-aggregate.\"));\n"
            "            }\n"
            "        }\n"
        ),
        "sample": "// unbounded distinct\nSyntheticEvents\n| distinct Category\n",
    },
    {
        "name": "ExpensiveEvaluatePlugin",
        "level": "warning",
        "weight": 2,
        "analyzerBlock": (
            "        foreach (var x in root.GetDescendants<EvaluateOperator>())\n"
            "        {\n"
            "            if (x.ToString().Contains(\"bag_unpack\", StringComparison.OrdinalIgnoreCase))\n"
            "            {\n"
            "                violations.Add(Make(code, filePath, x.TextStart, \"KQLNNN\",\n"
            "                    \"'evaluate bag_unpack' materializes dynamic columns and can be expensive; project only the keys you need.\"));\n"
            "            }\n"
            "        }\n"
        ),
        "sample": "// expensive evaluate plugin\nSyntheticEvents\n| evaluate bag_unpack(Payload)\n",
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
        "- analyzerBlock MUST be one C# foreach over root.GetDescendants<T>() "
        "that flags ONLY the expensive pattern through an `if` GUARD inside the "
        "loop; it MUST NOT flag every match. The rule has to be SPECIFIC: it "
        "must stay silent on ordinary, well-written queries and fire only on the "
        "costly variant (an unconditional rule that flags every T is WRONG and "
        "will be rejected). Form: `foreach (var x in root.GetDescendants<T>()) "
        "{ if (<condition>) { violations.Add(Make(code, filePath, x.TextStart, "
        "\"" + assigned_id + "\", \"<message>\")); } }`. Prefer a robust "
        "condition that needs no deep API knowledge, e.g. "
        "`x.ToString().Contains(\"<kql-keyword>\", "
        "StringComparison.OrdinalIgnoreCase)` (optionally negated with !) or the "
        "absence/presence of a bounding operator via "
        "`root.GetDescendants<AllowedType>().Count == 0`.\n"
        "- T (and any type you pass to GetDescendants<> in the condition) MUST "
        "be copied VERBATIM from the ALLOWED_NODE_TYPES list below (never "
        "invent, abbreviate, or add a suffix to a name — there is no "
        "'InCsExpression'; the `in` operator is 'InExpression'). Choose the T "
        "matching the most expensive structural feature of the shape.\n"
        "- sample MUST be synthetic KQL: invented table and column names, NO real "
        "identifiers or literal values, and it MUST trigger the rule.\n"
        "- sampleSlug MUST be kebab-case (lowercase letters, digits, hyphens).\n"
        "- level MUST be 'warning' or 'error'; weight MUST be a small positive "
        "integer.\n"
        "ALLOWED_NODE_TYPES (Kusto.Language syntax node types; use exactly ONE, "
        "verbatim, as T):\n" + ", ".join(NODE_TYPES) + "\n"
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
    target = re.search(r"GetDescendants<\s*([A-Za-z0-9_]+)\s*>", block)
    if not target or target.group(1) not in NODE_TYPES:
        raise ValueError("analyzerBlock targets an unknown Kusto.Language node type: %s"
                         % (target.group(1) if target else "<none>"))
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
