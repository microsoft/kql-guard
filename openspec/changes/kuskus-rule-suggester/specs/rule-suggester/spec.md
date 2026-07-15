## ADDED Requirements

### Requirement: Strict trust boundary

The pipeline SHALL ensure raw corpus query text never appears in workflow logs, pull requests, issues, or committed files. Only aggregate statistics, rule identifiers, abstracted shape signatures, and diffs that have passed the leak-guard SHALL cross into the public repository. Corpus text handling SHALL be kept out of command tracing, and the corpus fetch SHALL print only counts, never query contents.

#### Scenario: The job summary exposes only aggregate data

- **WHEN** the pipeline writes its run report to the workflow job summary
- **THEN** the summary contains only rule identifiers, counts, cost totals, and abstracted shape signatures — and no raw query text

#### Scenario: A candidate carrying corpus text cannot become a PR

- **WHEN** a candidate diff contains verbatim text from a fetched corpus query
- **THEN** the pipeline blocks it and no pull request is opened

### Requirement: Existing-rule frequency report

On each run the pipeline SHALL produce, from `kql-guard --format json` over the fetched corpus, a report of how often each existing rule fires (rule identifier to count), plus totals and summed cost, and write it to the workflow job summary. This report SHALL NOT require analyzer code beyond the existing JSON output (it is derived with `jq`).

#### Scenario: The report lists per-rule frequencies

- **WHEN** the corpus produces findings across several rules
- **THEN** the job summary lists each rule identifier with its occurrence count and an overall total

### Requirement: Candidate discovery

The pipeline SHALL rank recurring query shapes using `kql-guard mine` and SHALL select as new-rule candidates the shapes that recur frequently and have a `WithExistingFinding` of 0 (recurring shapes the current ruleset does not flag).

#### Scenario: A frequent unflagged shape is selected

- **WHEN** a shape recurs often with `WithExistingFinding` of 0
- **THEN** it is selected as a new-rule candidate

#### Scenario: A frequent already-flagged shape is not selected

- **WHEN** a shape recurs often but its queries already trigger an existing rule
- **THEN** it is not selected as a new-rule candidate

### Requirement: In-boundary AI drafting

For each selected candidate, an in-boundary AI step SHALL draft a change limited to a `RuleInfo` entry, an analyzer block, a single synthetic sample query, and a test assertion, following the existing rule template. The AI provider SHALL be pluggable and run inside the trust boundary, and no raw corpus text SHALL be sent outside that boundary. Sample fixtures the AI produces SHALL be synthetic.

#### Scenario: The drafted diff is confined to the rule template

- **WHEN** the AI drafts a candidate
- **THEN** the diff touches only the rule registry, the analyzer, a new synthetic sample file, and the test script — no other files

#### Scenario: The drafted sample is synthetic

- **WHEN** the AI produces the sample query that triggers its drafted rule
- **THEN** the sample is synthetic and shares no verbatim text with any corpus query

### Requirement: Fail-closed validation gate

Before a candidate can become a pull request, the pipeline SHALL apply the drafted diff and require all of: the test suite (`./test/run-tests.sh`) passes, the NativeAOT release publish succeeds, and the newly drafted rule fires on fewer than a configured threshold percentage of the corpus. If any check fails, the candidate SHALL be discarded and no pull request opened.

#### Scenario: A draft that breaks tests is discarded

- **WHEN** applying a candidate diff causes `./test/run-tests.sh` to fail
- **THEN** the candidate is discarded and no pull request is opened

#### Scenario: An over-reporting rule is discarded

- **WHEN** a drafted rule fires on more than the configured threshold percentage of the corpus
- **THEN** the candidate is discarded as too noisy

#### Scenario: A passing draft proceeds

- **WHEN** a candidate passes the tests, the NativeAOT publish, and the over-report check
- **THEN** it proceeds to the leak-guard and publishing steps

### Requirement: Leak-guard

Before any candidate crosses into the public repository, the pipeline SHALL scan the entire outgoing diff for token-shingle overlap with any fetched corpus query and SHALL block the candidate if any overlap is found. This check SHALL run regardless of the AI's instructions and SHALL NOT be bypassable by the drafting step.

#### Scenario: A diff overlapping a corpus query is blocked

- **WHEN** the outgoing diff shares a multi-token shingle with any fetched corpus query
- **THEN** the candidate is blocked and no pull request is opened

#### Scenario: A purely synthetic diff passes

- **WHEN** the outgoing diff shares no multi-token shingle with any fetched corpus query
- **THEN** the leak-guard permits the candidate to proceed

### Requirement: Idempotent PR publishing

The pipeline SHALL fingerprint each candidate by its shape signature and SHALL NOT open a duplicate pull request when a rule already covers the shape or when an open pull request or branch for that fingerprint already exists. Otherwise it SHALL open or update a review pull request describing the abstracted shape, its frequency, and the validated rule and synthetic tests, and request maintainer review.

#### Scenario: A duplicate candidate is skipped

- **WHEN** a candidate's fingerprint already has an open pull request or branch
- **THEN** the pipeline does not open a second pull request for it

#### Scenario: A new candidate opens a review PR

- **WHEN** a validated, leak-clean candidate has no existing pull request or covering rule
- **THEN** the pipeline opens a pull request carrying the abstracted shape, its frequency, and the validated rule and tests, requesting maintainer review

### Requirement: Scheduling and runner state

The pipeline SHALL run on a schedule and on manual dispatch, on a self-hosted runner with corpus access, and SHALL persist its fetch watermark and its set of proposed-candidate fingerprints outside the public repository. A dispatch input SHALL allow running against a supplied local corpus path, bypassing the fetch step. A fetch failure SHALL leave the watermark unchanged and open no pull request.

#### Scenario: A scheduled run advances the watermark

- **WHEN** a scheduled run fetches queries created since the stored watermark and completes successfully
- **THEN** the watermark advances so the next run does not re-fetch the same queries

#### Scenario: A dispatch run can bypass fetch

- **WHEN** the workflow is dispatched with a local corpus path input
- **THEN** the pipeline analyzes that path without invoking the fetch step

#### Scenario: A fetch failure is a safe no-op

- **WHEN** the fetch step fails
- **THEN** the watermark is left unchanged and no pull request is opened

### Requirement: Deferred integrations shipped as contracts

The real Kuskus fetch and the provider-specific AI wiring SHALL be shipped as documented contracts plus stubs; this change SHALL NOT contain any live corpus access or external model endpoint. The deferrals SHALL be marked in code and documentation so they are visible rather than hidden, and the pipeline SHALL be runnable end-to-end against a supplied corpus path using a local mock suggester.

#### Scenario: The fetch stub is a clear, safe placeholder

- **WHEN** the fetch stub runs without a real implementation provided
- **THEN** it fails with a clear message directing the operator to supply the real fetch, and the pipeline can still run against a supplied corpus path

#### Scenario: The pipeline runs end-to-end with the mock suggester

- **WHEN** the workflow is dispatched with a local corpus path and the mock suggester
- **THEN** it produces the job-summary report and can carry a mock candidate through validation, leak-guard, and PR publishing without any live corpus access or external model call
