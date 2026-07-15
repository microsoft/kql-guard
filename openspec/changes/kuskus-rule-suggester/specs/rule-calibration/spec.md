## ADDED Requirements

### Requirement: Finding-to-cost correlation

The `kql-guard calibrate` subcommand SHALL read fetched `QueryCompletion` rows (query text plus the execution-cost fields derived from `Duration`, `TotalCPU`, `MemoryPeak`, and the scanned-rows/extents in `ScannedExtentsStatistics`), run the existing analyzer in-process over each parseable query, and, for each rule identifier, report an aggregate of the real execution cost of the queries that triggered it: the firing count and the median and p95 of duration, scanned rows, CPU, and peak memory. It SHALL also report the same aggregates over a baseline of queries that produced no findings. The subcommand SHALL NOT emit any raw query text in any output format.

#### Scenario: A rule's flagged queries report a cost distribution

- **WHEN** several corpus queries trigger a rule and carry execution-cost fields
- **THEN** calibrate reports that rule's firing count and the median and p95 duration, scanned rows, CPU, and peak memory of those queries

#### Scenario: A no-findings baseline is reported

- **WHEN** some corpus queries produce no findings
- **THEN** calibrate reports the same cost aggregates over that no-findings baseline for comparison

#### Scenario: Output contains no raw query text

- **WHEN** calibrate emits its report in any format
- **THEN** the output contains only rule identifiers, counts, and cost aggregates — and no query text

### Requirement: Weight-disagreement signal

For each cost rule, calibrate SHALL compute the rule's rank by real median cost across the corpus and compare it to the rank implied by its declared `CostWeight`, and SHALL flag rules whose real-cost rank materially disagrees with their weight rank as weight-review candidates. calibrate SHALL NOT compute or apply a new weight value; it SHALL only surface the disagreement and the supporting aggregates for human review.

#### Scenario: An over-weighted rule is flagged

- **WHEN** a rule has a high declared weight but its flagged queries are consistently cheap relative to other rules
- **THEN** calibrate flags it as a weight-review candidate (potential down-weight) without proposing a specific value

#### Scenario: A well-aligned rule is not flagged

- **WHEN** a rule's real-cost rank matches the rank implied by its declared weight
- **THEN** calibrate does not flag it

### Requirement: Failure-catch measurement

For corpus rows whose `State` is `Failed` and that carry a `FailureReason`, calibrate SHALL run the analyzer and report what fraction kql-guard would have flagged before execution, split into catchable classes (syntax errors, and schema errors where the schema is available) versus classes that require table schema kql-guard does not have offline. The report SHALL NOT overstate coverage of schema-dependent failures.

#### Scenario: A syntactically invalid failed query is counted as catchable

- **WHEN** a failed query's `FailureReason` is a syntax error and kql-guard's parser rejects the query
- **THEN** calibrate counts it in the catchable fraction

#### Scenario: A schema-dependent failure is reported as such

- **WHEN** a failed query's `FailureReason` is a semantic error that requires table schema to detect
- **THEN** calibrate counts it in the schema-dependent class rather than the catchable fraction

### Requirement: Readable-dialect filtering

calibrate SHALL process only the readable KQL dialect and SHALL skip rows in the engine's expanded/internal serialization (identified by markers such as `__invoke(`, bracket-quoted identifiers, and `assert-schema`), reporting how many rows were skipped so the aggregates are understood as covering the readable subset. Queries that fail to parse SHALL also be skipped, not aggregated.

#### Scenario: Expanded-dialect rows are excluded and counted

- **WHEN** the corpus contains rows in the engine's expanded/internal form
- **THEN** calibrate excludes them from the cost aggregates and reports the skipped count

### Requirement: AOT-safe JSON output

When `--format json` is given, calibrate SHALL serialize its report through the source-generated JSON context, without reflection-based serialization, so the single-binary NativeAOT publish continues to succeed.

#### Scenario: JSON report is machine-readable

- **WHEN** `calibrate <path> --format json` runs
- **THEN** the output is valid JSON listing, per rule, its firing count, its cost aggregates, and its weight-disagreement flag
