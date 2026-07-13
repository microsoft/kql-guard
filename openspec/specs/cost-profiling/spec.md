# cost-profiling Specification

## Purpose
TBD - created by archiving change finops-cost-profiler. Update Purpose after archive.
## Requirements
### Requirement: Static cost-profiling rules

The system SHALL detect high-cost KQL query shapes by traversing the parsed AST offline, without any database connection, network call, or credentials. Each detected shape SHALL be emitted as a `Violation` with a stable rule ID and an associated relative cost weight.

The rules and their weights SHALL be:

| Rule ID | Detects | Weight |
|---------|---------|--------|
| KQL002 | `contains` / `contains_cs` operator (existing rule, folded into scoring) | 1 |
| KQL003 | A table query with no time-range filter (`ago(...)`, `between (...)`, or a comparison against a datetime/`TimeGenerated`-style column) | 5 |
| KQL004 | `search` with no table scope (`search "x"` / `search *`) | 5 |
| KQL005 | `union` over a wildcard table set (`union *`, `union pattern*`) | 4 |
| KQL006 | `join` where neither input is time-bounded | 3 |
| KQL007 | Regex-heavy operations: `matches regex` operator, or `extract` / `extract_all` / `parse` with a regex argument | 2 |
| KQL008 | A query that returns table rows with no column or row reduction (`project`, `project-away`, `summarize`, or `take`/`limit`) | 1 |

Heuristic rules (KQL003, KQL006, KQL008) MAY produce false positives; their weights SHALL be defined together in one place so they can be tuned without code changes elsewhere.

#### Scenario: A query missing a time filter is flagged

- **WHEN** a `.kql` file contains a table query with no `ago()`, `between`, or datetime-column comparison
- **THEN** the tool emits a KQL003 finding with cost weight 5 at the query's location

#### Scenario: An unscoped search is flagged

- **WHEN** a query uses `search "term"` or `search *` with no table specified
- **THEN** the tool emits a KQL004 finding with cost weight 5

#### Scenario: A wildcard union is flagged

- **WHEN** a query uses `union *` or `union <prefix>*`
- **THEN** the tool emits a KQL005 finding with cost weight 4

#### Scenario: An unwindowed join is flagged

- **WHEN** a query joins two inputs and neither input is time-bounded
- **THEN** the tool emits a KQL006 finding with cost weight 3

#### Scenario: A regex-heavy operation is flagged

- **WHEN** a query uses `matches regex`, or `extract`/`extract_all`/`parse` with a regex pattern
- **THEN** the tool emits a KQL007 finding with cost weight 2

#### Scenario: A query with no column or row reduction is flagged

- **WHEN** a query returns table rows without any `project`, `project-away`, `summarize`, `take`, or `limit`
- **THEN** the tool emits a KQL008 finding with cost weight 1

#### Scenario: A clean, time-bounded, scoped query is not flagged

- **WHEN** a query is time-bounded, scoped to a named table, and reduces columns/rows
- **THEN** no cost findings (KQL002–KQL008) are emitted for that query

### Requirement: Per-file cost score

The system SHALL compute, for each analyzed `.kql` file, a cost score equal to the sum of the weights of all cost findings (KQL002–KQL008) in that file. Syntax errors (KQL001) SHALL NOT contribute to the cost score. A file with no cost findings SHALL have a score of 0. The score SHALL be unitless; the system SHALL NOT present it as a currency amount.

#### Scenario: Score sums finding weights

- **WHEN** a file produces a KQL003 (weight 5) and a KQL007 (weight 2) finding
- **THEN** that file's reported cost score is 7

#### Scenario: Clean file scores zero

- **WHEN** a file produces no cost findings
- **THEN** that file's reported cost score is 0

### Requirement: Cost score reporting

The system SHALL surface each file's cost score in both output formats. In text output, it SHALL print one summary line per file in the form `<path>: cost score <n>`. In SARIF output, the score SHALL be carried as a run-level property and SHALL NOT corrupt the SARIF schema validity. The new rules KQL003–KQL008 SHALL appear in the SARIF run's rule metadata.

#### Scenario: Text output includes a per-file score line

- **WHEN** the tool analyzes a file in default (text) mode
- **THEN** the output includes a line `<path>: cost score <n>` for that file

#### Scenario: SARIF output remains valid and includes new rules

- **WHEN** the tool analyzes files with `--format sarif`
- **THEN** the emitted SARIF is schema-valid, lists KQL003–KQL008 in the driver rules, and includes the cost score as a run property

### Requirement: Optional budget gate

The system SHALL accept an optional `--max-cost <int>` flag. When provided, if any analyzed file's cost score exceeds the given budget, the tool SHALL exit with a non-zero status. When the flag is omitted, the cost score SHALL NOT affect the exit status. Existing exit-code semantics SHALL be preserved: `0` when clean, `1` when findings exist or the budget is breached, `2` on a usage error.

#### Scenario: Budget breach fails the build

- **WHEN** `--max-cost 4` is given and a file scores 7
- **THEN** the tool exits non-zero (1)

#### Scenario: Within budget does not fail on score alone

- **WHEN** `--max-cost 10` is given and the highest file score is 7 with no other errors
- **THEN** the budget gate does not, by itself, cause a non-zero exit

#### Scenario: No flag means score does not gate

- **WHEN** `--max-cost` is not supplied
- **THEN** the cost score has no effect on the exit status

### Requirement: Cost enrichment seam

The system SHALL define an `ICostEnricher` abstraction capable of adjusting a finding's cost weight given the queried table's name. The default implementation `NullCostEnricher` SHALL return the static weight unchanged. This change SHALL NOT perform any live API call, authentication, or network request; the seam exists solely so a future change can supply real table sizing without refactoring the scoring pipeline.

#### Scenario: Default enricher preserves static weights

- **WHEN** the tool runs with the default `NullCostEnricher`
- **THEN** every finding's cost weight equals its statically defined weight, and no network call is made

