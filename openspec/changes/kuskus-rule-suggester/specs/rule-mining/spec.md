## ADDED Requirements

### Requirement: Shape-clustering subcommand

The system SHALL provide a `kql-guard mine <path> [--format json] [--top N]` subcommand that, for every readable-dialect, parser-clean query under the path, computes a normalized AST **shape signature** which preserves KQL operator syntax kinds and built-in function names while omitting user identifiers, literals, and user-defined function names; groups queries by signature; and reports the resulting clusters. The subcommand SHALL skip rows in the engine's expanded/internal dialect (markers such as `__invoke(`, bracket-quoted identifiers, and `assert-schema`) and queries that fail to parse (KQL001), and SHALL NOT emit any raw query text in any output format.

#### Scenario: Structurally identical queries cluster together

- **WHEN** two readable-dialect queries have the same operator/function structure but different table names, column names, and literals
- **THEN** `mine` reports them in a single cluster with an occurrence count of 2

#### Scenario: Structurally different queries do not cluster

- **WHEN** two queries differ in their operator/function structure
- **THEN** `mine` reports them in two separate clusters

#### Scenario: Output contains no identifiers or literals

- **WHEN** `mine` reports a cluster's shape signature
- **THEN** the signature contains no table names, column names, string/number literals, or user-defined function names from the input queries

#### Scenario: Expanded-dialect rows are skipped

- **WHEN** the corpus contains rows in the engine's expanded/internal form
- **THEN** `mine` does not cluster them

### Requirement: Existing-finding correlation

For each cluster, the system SHALL report `WithExistingFinding`: the number of member queries that produce at least one existing kql-guard finding when analyzed by the current ruleset. This lets a caller isolate recurring shapes that the current ruleset does not flag (high count, `WithExistingFinding` of 0).

#### Scenario: An already-flagged shape reports a non-zero correlation

- **WHEN** every query in a cluster already triggers an existing rule (e.g. `contains` → KQL002)
- **THEN** that cluster's `WithExistingFinding` equals its occurrence count

#### Scenario: A clean, unflagged shape reports zero correlation

- **WHEN** no query in a cluster triggers any existing rule
- **THEN** that cluster's `WithExistingFinding` is 0

### Requirement: Cost-ranked ordering

The system SHALL rank clusters by the real execution cost of their member queries (for example, median duration or median scanned rows drawn from the corpus rows), so that `--top N` surfaces the highest-cost recurring shapes rather than merely the most frequent. `--top N` SHALL limit output to the N highest-cost clusters, and a sensible default SHALL apply when the flag is omitted. The ranking SHALL allow isolating clusters with `WithExistingFinding` of 0.

#### Scenario: The highest-cost recurring shapes surface first

- **WHEN** `mine <path> --top 3` runs over a corpus with more than three distinct shapes
- **THEN** at most three clusters are emitted, and they are the three highest-cost clusters

#### Scenario: A cheap frequent shape does not outrank an expensive one

- **WHEN** a frequent shape's queries are consistently cheap and a rarer shape's queries are consistently expensive
- **THEN** the expensive shape ranks above the cheap one

### Requirement: AOT-safe JSON output

When `--format json` is given, the system SHALL serialize the ranked clusters (`Shape`, `Count`, `WithExistingFinding`, and the cost aggregate) through the source-generated JSON context, without reflection-based serialization, so the single-binary NativeAOT publish continues to succeed.

#### Scenario: JSON output is machine-readable

- **WHEN** `mine <path> --format json` runs
- **THEN** the output is valid JSON listing, per cluster, its shape signature, count, `WithExistingFinding`, and cost aggregate
