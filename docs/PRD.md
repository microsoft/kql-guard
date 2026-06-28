# kql-guard — Product Requirements Document (PRD)

## 1. Problem

As SOCs migrate to Microsoft Sentinel and Azure Data Explorer (ADX), KQL has
become mission-critical, version-controlled software managed under "Detection as
Code" (DaC). The surrounding developer tooling — linters, formatters, cost
guards — is absent or fragmented. The community asked Microsoft to extract its
internal KQL validation as a standalone linter (Azure-Sentinel issue #12814);
the request was declined, leaving brittle PowerShell workarounds that download
`Kusto.Language`, inject DLLs, and shell out in CI.

## 2. Goal

Be the canonical, offline KQL Developer Kit: a single fast binary that lints,
profiles cost, and formats KQL in any CI runner — no live database, no .NET
runtime required at execution time.

## 3. Users

- Detection engineers writing Sentinel/ADX rules under DaC.
- Platform/DevSecOps teams gating pull requests.
- FinOps owners who want runaway-query risk caught before merge, not after the bill.

## 4. Principles

- **Offline first.** Parse the AST with `Kusto.Language`; no network, no auth.
- **Fast.** NativeAOT binary, instant startup in ephemeral runners.
- **Honest.** Cost is a relative, unitless score — never a fabricated dollar figure.
- **CI-native.** Compiler-style diagnostics + SARIF for code-scanning annotations.

## 5. Features (delivered)

1. Static analysis: syntax errors + performance/cost anti-patterns (KQL001–013).
2. FinOps cost profiler: per-finding weights, per-file score, `--max-cost` gate.
3. Offline enrichment: `--table-sizes` scales scan-rule weights per table.
4. Deterministic formatter (`fmt`): check / write, idempotent.
5. Output: text, SARIF v2.1.0, JSON.
6. Inline suppressions: `// kql-guard:disable[-next-line|-file]`.
7. Distribution: composite GitHub Action, Docker image, super-linter path.
8. Sentinel `.yaml` detection rules: lint the embedded query in place.
9. Baseline: ratchet on existing repos — fail only on newly introduced findings.

## 6. Success metrics

- Single-binary scan of a detections repo in < 1s on a cold runner.
- Zero false-positive syntax errors on valid KQL.
- PRs annotated via SARIF with cost-score summaries.

## 7. Non-goals

- Live billing prediction in dollars (impossible offline; behind opt-in seam).
- Executing queries or connecting to a cluster.

## 8. Roadmap

Live-API enrichment (`ICostEnricher`), upstream into GitHub super-linter.
