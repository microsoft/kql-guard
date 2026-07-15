## ADDED Requirements

### Requirement: Shape-clustering subcommand

The system SHALL provide a `kql-guard mine <path> [--format json] [--top N]` subcommand that, for every parser-clean query under the path, computes a normalized AST **shape signature** which preserves KQL operator syntax kinds and built-in function names while omitting user identifiers, literals, and user-defined function names; groups queries by signature; and reports the resulting clusters ranked by descending occurrence count. The subcommand SHALL NOT emit any raw query text in any output format. Queries that fail to parse (KQL001) SHALL be skipped, not clustered.

#### Scenario: Structurally identical queries cluster together

- **WHEN** two queries have the same operator/function structure but different table names, column names, and literals
- **THEN** `mine` reports them in a single cluster with an occurrence count of 2

#### Scenario: Structurally different queries do not cluster

- **WHEN** two queries differ in their operator/function structure
- **THEN** `mine` reports them in two separate clusters

#### Scenario: Output contains no identifiers or literals

- **WHEN** `mine` reports a cluster's shape signature
- **THEN** the signature contains no table names, column names, string/number literals, or user-defined function names from the input queries

### Requirement: Existing-finding correlation

For each cluster, the system SHALL report `WithExistingFinding`: the number of member queries that produce at least one existing kql-guard finding when analyzed by the current ruleset. This lets a caller isolate recurring shapes that the current ruleset does not flag (high count, `WithExistingFinding` of 0).

#### Scenario: An already-flagged shape reports a non-zero correlation

- **WHEN** every query in a cluster already triggers an existing rule (e.g. `contains` → KQL002)
- **THEN** that cluster's `WithExistingFinding` equals its occurrence count

#### Scenario: A clean, unflagged shape reports zero correlation

- **WHEN** no query in a cluster triggers any existing rule
- **THEN** that cluster's `WithExistingFinding` is 0

### Requirement: AOT-safe JSON output

When `--format json` is given, the system SHALL serialize the ranked clusters (`Shape`, `Count`, `WithExistingFinding`) through the source-generated JSON context, without reflection-based serialization, so the single-binary NativeAOT publish continues to succeed.

#### Scenario: JSON output is machine-readable

- **WHEN** `mine <path> --format json` runs
- **THEN** the output is valid JSON listing, per cluster, its shape signature, count, and `WithExistingFinding`

### Requirement: Top-N limiting

The system SHALL accept `--top N` to limit output to the N highest-count clusters, and SHALL apply a sensible default when the flag is omitted.

#### Scenario: Only the highest-count clusters are emitted

- **WHEN** `mine <path> --top 3` runs over a corpus with more than three distinct shapes
- **THEN** at most three clusters are emitted, and they are the three with the highest counts
