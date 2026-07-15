## Context

kql-guard is a ~1300-line NativeAOT .NET CLI whose rules are baked into the binary and authored by hand. Rule IDs: `KQL001` (syntax), `KQL002`–`KQL013` (cost, advisory), `KQL101` (schema). A rule is a tightly-templated unit: a `RuleInfo` entry in `Rules.All`, an AST-walk block in `CostAnalyzer.Analyze`, a `samples/cost/<name>.kql` fixture that triggers exactly one rule, and one `assert_contains` line in `test/run-tests.sh` (`CostRules.cs`, `test/run-tests.sh`).

We want to feed rule authorship with evidence from **Kuskus**, an internal Microsoft corpus of Sentinel / hunting KQL. The defining constraint: Kuskus is confidential and this repo will be public. So the whole design hangs on one invariant — **raw corpus text never crosses from the runner into the public repository.**

There is a near-zero-code baseline for the existing-rule histogram: `kql-guard <dir> --format json | jq -r '.Findings[].Rule' | sort | uniq -c | sort -rn`. Anything built here must clearly beat that one line. The histogram therefore stays a `jq` step (no code); only genuinely new capability earns code.

## Goals / Non-Goals

**Goals:**
- A deterministic `kql-guard mine` subcommand that ranks recurring AST shapes and flags which recur *without* an existing finding.
- A scheduled pipeline that reports existing-rule frequency and opens human-reviewed PRs drafting new rules for the top unflagged shapes.
- Strict confidentiality: only aggregate stats, abstracted signatures, and leak-guard-passed diffs cross into the public repo.
- Every automated step fails closed; no low-quality or leaky PR can be opened unattended.

**Non-Goals:**
- No auto-merge. Every rule change is a PR a maintainer reviews and merges.
- No live Kuskus access or specific AI endpoint in this change (shipped as contracts + stubs; real wiring is a later change).
- No new binary dependencies; `mine` stays offline and NativeAOT-safe (source-gen JSON only).
- No dollar figures, no semantic/ML clustering in v1 — structural (AST-shape) clustering only.

## Trust boundary (the backbone)

```
schedule / workflow_dispatch  ──►  self-hosted runner (in-boundary)
  ① fetch (stub)      watermark → pull Kuskus since it → scratch/   (count only to logs)
  ② analyze           kql-guard scratch/ --format json │ jq   → existing-rule histogram
                      kql-guard mine scratch/ --format json   → ranked shapes (+WithExistingFinding)
  ③ AI suggester      top-N unflagged shapes → draft RuleInfo + Analyze block + SYNTHETIC sample + test
  ④ validate  FAIL-CLOSED   run-tests.sh + dotnet publish -c Release -r linux-x64 + over-report (<T%)
  ⑤ leak-guard FAIL-CLOSED  outgoing diff shares NO token-shingle with scratch/
  ═══════════════════════ boundary ═══════════════════════
  ⑥ publish           job-summary (aggregate) + idempotent review PR (no verbatim queries)
```

Everything above the boundary line touches raw corpus text and runs only on the runner. Exactly two things cross below it: the aggregate job-summary and a PR diff that passed the leak-guard. Fetch watermark and proposed-candidate fingerprints persist on the runner, never in the repo.

## Decisions

**1. `mine` is a new subcommand, the histogram is not.** Shape clustering needs the parsed AST, which only the binary builds; re-parsing KQL in a script would reinvent `Kusto.Language`. The rule-ID histogram needs no AST — it's `jq` over existing `--format json`. So exactly one thing becomes code. *Alternative rejected:* a `report` subcommand that also does the histogram — redundant with `jq`.

**2. Shape signature = AST node kinds + builtin names, identifiers/literals stripped.** Walk the parsed tree in source order; emit each node's syntax kind; for operators keep the kind (e.g. `WhereOperator`, `JoinOperator` — pure syntax); for function calls keep the name only if it is a known `Kusto.Language` builtin, else normalize to `<fn>`; normalize every identifier (`NameReference`) to `<id>` and every literal to `<lit>`. The result preserves *which operators/builtins* recur (the signal) while dropping table/column names, string/number values, and user-defined function names (the sensitive parts). *Note:* the signature is a best-effort abstraction; the leak-guard (⑤) is the real enforcement backstop (defense in depth), not the signature.

**3. Novelty = frequency AND `WithExistingFinding == 0`.** A frequent shape is usually a *good* query. `mine` runs the same `CostAnalyzer` internally and, per cluster, counts how many member queries already produce a finding. Candidates are high-count clusters with `WithExistingFinding == 0` — recurring shapes the ruleset is blind to. This deterministic filter grounds the AI so it drafts rules for patterns that actually recur, not hallucinations. *Alternative rejected:* AI-first over raw query batches — unranked, non-deterministic, no frequency grounding.

**4. AI drafts only a templated diff, and validation is the gate — not trust.** The AI (in-boundary, provider pluggable, Azure OpenAI in-tenant as default) may only touch the four rule-template files. Its output is never trusted on faith: the pipeline applies the diff and requires `./test/run-tests.sh` to pass, the NativeAOT release publish to succeed, and the new rule to fire on `< T%` of the corpus (a rule that flags everything is noise). Any failure discards the candidate. The AI step is not deterministically unit-testable; its check *is* gate ④.

**5. The leak-guard is what lets AI-authored content cross the boundary.** Instructions ("emit only synthetic examples") can fail; a deterministic check cannot be bypassed. Before crossing, the entire outgoing diff is shingled (whitespace-normalized k-token n-grams) and compared against every fetched query; any overlap blocks the candidate. Synthetic tests are required precisely so this check can be strict.

**6. PRs are idempotent, fingerprinted by shape.** Branch `kuskus/rule-<fingerprint>`; skip if a rule already covers the shape (the `WithExistingFinding` filter) or a PR/branch for that fingerprint already exists. Otherwise open/update a review PR carrying the abstracted shape, its frequency, and the validated rule + synthetic tests. Proposed fingerprints persist on the runner so weekly runs don't re-propose.

**7. Fetch + AI provider ship as contracts + stubs.** The real Kuskus fetch needs infra that does not exist yet (a runner with corpus access, an auth story) and the in-tenant AI endpoint likewise. This change ships their **contracts** (documented I/O + a stub that fails with a clear message, and a local mock suggester for tests) so the pipeline runs end-to-end today against a `workflow_dispatch` `corpus_path`. Deferrals are marked with `ponytail:` comments and a Placeholders section — visible, not hidden.

## Alternatives considered: relaxing the trust boundary

The strict boundary costs real machinery (in-boundary model, synthetic examples, leak-guard). It blocks two distinct leaks; relaxing either would simplify differently, and this is recorded so a future maintainer can revisit deliberately:

| Relaxation | What it unlocks | What it costs |
|------------|-----------------|---------------|
| **Leak 1 only** (query text → AI vendor OK) | any external frontier API + hosted embeddings (semantic clustering); near-zero AI infra | still keep synthetic examples + leak-guard (repo still protected); detection logic goes to a third party |
| **Leak 2 only** (query text → public repo OK) | **real** corpus queries as fixtures/PR examples — delete synthetic-gen and the entire leak-guard | detection patterns become public; model stays in-tenant |
| **Both** ("easy mode") | external API + real examples; only over-report + `mine` remain | no confidentiality |

The over-report check and `mine`'s deterministic ranking are invariant across all four — they are quality gates, not secrecy gates. Architecturally the strict design is "easy mode + two isolated guardrails," so a future relaxation is a *deletion* (drop the in-boundary constraint and/or leak-guard), not a re-architecture. Committing to strict now costs nothing later.

## Risks

- **Synthetic-example quality.** The AI must invent a query that triggers its own drafted rule; a weak fixture passes `run-tests.sh` but poorly represents the real shape. Mitigated by the over-report check and mandatory human review — never auto-merge.
- **Signature over/under-collapsing.** One fixed normalization may cluster too coarsely or finely. Ponytail: one level now; add knobs when a real cluster proves wrong (the ranking is the observable signal).
- **Leak-guard false negatives** (heavily reworded real query). Mitigated by defense in depth: in-boundary model + synthetic-only instruction + shingle scan + human review. False *positives* (synthetic text incidentally overlapping) simply drop a candidate — safe.
