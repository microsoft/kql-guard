# New-rule suggester contract

The mining pipeline selects a recurring, unflagged, high-cost shape and asks an
in-boundary suggester to draft a rule for it. The suggester is pluggable via the
`SUGGESTER_CMD` env var (default: `python3 scripts/mock-suggester.py`). It runs
**inside the trust boundary**; no corpus text is ever sent to it beyond the
already-abstracted shape signature, and it must emit only synthetic content.

## Input (stdin, JSON) — a candidate cluster (no query text)

```json
{ "signature": "<abstracted shape>", "count": 42, "medianDurationMs": 1234.5 }
```

## Output (stdout, JSON) — a candidate spec confined to the rule template

```json
{
  "id": "KQL014",
  "name": "PascalCaseRuleName",
  "shortDescription": "One-line rule description for the registry.",
  "level": "warning",
  "weight": 2,
  "message": "Operator-level diagnostic message.",
  "analyzerBlock": "        // KQL014 ...\n        foreach (...) { violations.Add(Make(...)); }\n",
  "sample": "SyntheticTable\n| ...\n",
  "sampleSlug": "kebab-slug",
  "signature": "<echo of the input signature, for PR fingerprinting>",
  "count": 42,
  "medianDurationMs": 1234.5
}
```

`signature`, `count`, and `medianDurationMs` are echoed straight from the input:
they are already-abstracted aggregates (never query text) and become the PR's
review evidence. Everything else must be synthetic.

The drafted diff may touch only: `CostRules.cs` (a `RuleInfo` entry + the
`analyzerBlock` inside `CostAnalyzer.Analyze`), `samples/cost/<sampleSlug>.kql`,
and one assertion in `test/run-tests.sh`. The pipeline enforces this via
`apply-candidate.py` (mechanical insertion) and the validation gate; nothing the
suggester writes is trusted — it is validated (build + tests + over-report +
leak-guard) before it can become a PR.

## Deferred: real provider

`ponytail:` the real in-tenant Azure OpenAI wiring is deferred. Set
`SUGGESTER_CMD` to a provider adapter that honors this same stdin/stdout
contract; no other pipeline change is needed. The mock below makes the whole
path runnable and testable today with zero external calls.
