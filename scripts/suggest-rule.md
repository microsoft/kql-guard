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

## Real provider: `scripts/aoai-suggester.py` (Azure OpenAI)

The live drafter for the runner. Same stdin/stdout contract as above; the mock
(`scripts/mock-suggester.py`) remains the default and the test double.

- **Auth:** the runner MI, via IMDS (`urllib`, no `azure-identity`). Token scope
  `https://cognitiveservices.azure.com`; `KUSKUS_MI_CLIENT_ID` selects the
  user-assigned identity.
- **Call:** `POST {KUSKUS_AOAI_ENDPOINT}/openai/deployments/{KUSKUS_AOAI_DEPLOYMENT}/chat/completions?api-version={KUSKUS_AOAI_API_VERSION}`
  with `response_format: json_schema` (structured outputs). `urllib`, no `openai` SDK.
- **Env:** `KUSKUS_AOAI_ENDPOINT`, `KUSKUS_AOAI_DEPLOYMENT`,
  `KUSKUS_AOAI_API_VERSION` (from the runner `.env`, provisioned in
  `infra/terraform`), `KUSKUS_MI_CLIENT_ID`.
- **Id ownership:** the adapter computes the next free cost-band id from
  `CostRules.cs` (`KQL0NN`, max+1) and injects it; the model never chooses the
  id, so it cannot collide (root cause of the closed PR #38).
- **Field ownership:** the model owns `name, shortDescription, level, weight,
  message, analyzerBlock, sample, sampleSlug`; the adapter sets `id` and echoes
  `signature, count, medianDurationMs`.
- **Fail-closed:** any error (auth, network, malformed/invalid model output)
  → stderr reason, nonzero exit, nothing on stdout. `run-mining.sh` degrades that
  to a job-summary skip line (green); `validate-candidate.sh` is the second wall
  (build + tests + over-report + leak-guard) before any branch is pushed.

### Boundary & the real-text upgrade (not built)

Approach A sends AOAI ONLY the masked shape signature, which is public-safe (it
already appears in PR bodies). So a public endpoint with default retention is
correct. The confidential upgrade feeds real query `Text` on stdin (a change to
the mining input, not this adapter) and therefore requires a private endpoint +
Zero-Data-Retention (Modified Abuse Monitoring); the contract, validate gate, and
leak-guard are unchanged.
