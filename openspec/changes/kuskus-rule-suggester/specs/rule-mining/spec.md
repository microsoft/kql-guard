## ADDED Requirements

### Requirement: Shape-signature emission

The analyzer SHALL, when requested via a `--shapes` flag on the existing analyze command, include in its `--format json` output a normalized per-query **shape signature** that preserves KQL operator syntax kinds and built-in function names while omitting user identifiers, literals, and user-defined function names, computed from the parsed AST. The signature SHALL be keyed by query (file) so callers can join it with findings and cost data, SHALL be serialized through the source-generated JSON context (NativeAOT-safe, no reflection), and SHALL contain no raw query text. Queries that fail to parse SHALL be omitted from the shapes map. This SHALL be a flag on the existing command, not a new subcommand.

#### Scenario: Structurally identical queries share a signature

- **WHEN** two queries have the same operator/function structure but different table names, column names, and literals
- **THEN** the emitted signature is identical for both queries

#### Scenario: Structurally different queries differ in signature

- **WHEN** two queries differ in their operator/function structure
- **THEN** their emitted signatures differ

#### Scenario: The signature contains no identifiers or literals

- **WHEN** the analyzer emits a query's shape signature
- **THEN** the signature contains no table names, column names, string/number literals, or user-defined function names from the query

#### Scenario: Shapes output stays NativeAOT-safe

- **WHEN** `--format json --shapes` is serialized
- **THEN** it goes through the source-generated JSON context and the single-binary NativeAOT publish still succeeds

### Requirement: Shape clustering

The mining step SHALL, from the per-query shape signatures (`kql-guard --format json --shapes`) and the readable-dialect corpus, group queries by identical signature and report the resulting clusters with their occurrence counts. It SHALL operate only on the readable dialect (the fetch having dropped expanded/internal and redacted rows) and SHALL NOT emit any raw query text.

#### Scenario: Structurally identical queries cluster together

- **WHEN** two readable-dialect queries share a shape signature
- **THEN** the mining step reports them in a single cluster with an occurrence count of 2

#### Scenario: Structurally different queries do not cluster

- **WHEN** two queries have different shape signatures
- **THEN** the mining step reports them in two separate clusters

### Requirement: Existing-finding correlation

For each cluster, the mining step SHALL report `WithExistingFinding`: the number of member queries that produce at least one existing kql-guard finding (from the same `--format json` output). This lets it isolate recurring shapes the current ruleset does not flag (high count, `WithExistingFinding` of 0).

#### Scenario: An already-flagged shape reports a non-zero correlation

- **WHEN** every query in a cluster already triggers an existing rule (e.g. `contains` → KQL002)
- **THEN** that cluster's `WithExistingFinding` equals its occurrence count

#### Scenario: A clean, unflagged shape reports zero correlation

- **WHEN** no query in a cluster triggers any existing rule
- **THEN** that cluster's `WithExistingFinding` is 0

### Requirement: Cost-ranked ordering

The mining step SHALL rank clusters by the real execution cost of their member queries (for example, median duration or median scanned rows from the cost manifest), so that the top results are the highest-cost recurring shapes rather than merely the most frequent, and SHALL support limiting output to the top N. It SHALL allow isolating clusters with `WithExistingFinding` of 0 as new-rule candidates.

#### Scenario: The highest-cost recurring shapes surface first

- **WHEN** the mining step ranks clusters and is limited to the top 3
- **THEN** at most three clusters are reported, and they are the three highest-cost clusters

#### Scenario: A cheap frequent shape does not outrank an expensive one

- **WHEN** a frequent shape's queries are consistently cheap and a rarer shape's queries are consistently expensive
- **THEN** the expensive shape ranks above the cheap one
