## ADDED Requirements

### Requirement: Finding-to-cost correlation

The calibration step SHALL, from `kql-guard --format json` over the fetched corpus (which attributes each finding to its query file, rule, and `CostWeight`) and the fetched per-query cost manifest (duration, CPU, peak memory, and scanned rows), report for each rule identifier an aggregate of the real execution cost of the queries that triggered it: the firing count and the median and p95 of duration, scanned rows, CPU, and peak memory. It SHALL also report the same aggregates over a baseline of queries that produced no findings. The output SHALL contain only rule identifiers, counts, and cost aggregates — no raw query text — so it can cross into the public job summary. This step SHALL require no new analyzer subcommand.

#### Scenario: A rule's flagged queries report a cost distribution

- **WHEN** several corpus queries trigger a rule and appear in the cost manifest
- **THEN** the calibration step reports that rule's firing count and the median and p95 duration, scanned rows, CPU, and peak memory of those queries

#### Scenario: A no-findings baseline is reported

- **WHEN** some corpus queries produce no findings
- **THEN** the calibration step reports the same cost aggregates over that no-findings baseline for comparison

#### Scenario: Output contains no raw query text

- **WHEN** the calibration step emits its report
- **THEN** the output contains only rule identifiers, counts, and cost aggregates — and no query text

### Requirement: Weight-disagreement signal

The calibration step SHALL compute each cost rule's rank by real median cost across the corpus and compare it to the rank implied by its declared `CostWeight` (read from the analyzer's JSON output), and SHALL flag rules whose real-cost rank materially disagrees with their weight rank as weight-review candidates. It SHALL NOT compute or apply a new weight value; it SHALL only surface the disagreement and the supporting aggregates for human review.

#### Scenario: An over-weighted rule is flagged

- **WHEN** a rule has a high declared weight but its flagged queries are consistently cheap relative to other rules
- **THEN** the calibration step flags it as a weight-review candidate (potential down-weight) without proposing a specific value

#### Scenario: A well-aligned rule is not flagged

- **WHEN** a rule's real-cost rank matches the rank implied by its declared weight
- **THEN** the calibration step does not flag it

### Requirement: Failure-catch measurement

For corpus rows whose manifest `state` is `Failed` and that carry a `failureReason`, the calibration step SHALL report what fraction kql-guard would have flagged before execution (by checking whether the query produced a syntax or schema finding), split into catchable classes (syntax errors, and schema errors where the schema is available) versus classes that require table schema kql-guard does not have offline. The report SHALL NOT overstate coverage of schema-dependent failures.

#### Scenario: A syntactically invalid failed query is counted as catchable

- **WHEN** a failed query's `failureReason` is a syntax error and kql-guard's parser rejects the query (KQL001)
- **THEN** the calibration step counts it in the catchable fraction

#### Scenario: A schema-dependent failure is reported as such

- **WHEN** a failed query's `failureReason` is a semantic error that requires table schema to detect
- **THEN** the calibration step counts it in the schema-dependent class rather than the catchable fraction

### Requirement: Generic over trace confidentiality

The calibration step SHALL operate identically whether the fetched corpus originates from the confidential full-text `QueryCompletion` tier or from a redacted trace view; confidentiality SHALL affect only which rows and how much text are present, not the correlation logic or its output contract.

#### Scenario: The same calibration runs on either trace tier

- **WHEN** the pipeline supplies a corpus and cost manifest from either the confidential full-text tier or a redacted trace view
- **THEN** the calibration step produces the same shape of aggregate report without code changes

### Requirement: Self-checked correlation logic

The calibration correlation SHALL ship with a runnable self-check that fails if the aggregation, ranking, or failure-catch logic breaks, using a small fixture of findings plus a cost manifest with known values.

#### Scenario: The self-check catches a broken aggregation

- **WHEN** the correlation logic mis-joins findings to costs or miscomputes an aggregate
- **THEN** the self-check fails
