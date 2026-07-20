# rule-suggester spec delta

## MODIFIED Requirements

### Requirement: Deferred integrations shipped as contracts

The provider-specific AI wiring SHALL be shipped as a real adapter honoring the
`suggest-rule.md` contract, not left as a stub. `scripts/aoai-suggester.py`
(Azure OpenAI, Approach A) SHALL draft new-rule candidates from the masked,
public-safe shape signature only, assigning the rule id mechanically from
`CostRules.cs` (the model never chooses it) and failing closed on any error. The
deterministic `scripts/mock-suggester.py` SHALL remain the default and the test
double, and SHALL be the only suggester used in CI and self-tests. No
confidential query text SHALL be transmitted to any external model endpoint: the
confidential real-text version (real query `Text` on stdin) remains deferred and
SHALL require a private endpoint with Zero-Data-Retention. All deferrals SHALL be
marked in code and documentation. The pipeline SHALL remain runnable end-to-end
against a supplied corpus path using the mock, and the primary calibration and
weight-review path SHALL require no AI provider at all.

#### Scenario: The calibration path runs without any AI

- **WHEN** the workflow is dispatched with a local corpus path
- **THEN** it produces the calibration cost report and can open mechanical weight-review pull requests without any AI provider configured

#### Scenario: The mining path runs end-to-end with the mock suggester

- **WHEN** the workflow is dispatched with a local corpus path and the mock suggester
- **THEN** it can carry a mock new-rule candidate through validation, leak-guard, and PR publishing without any live corpus access or external model call

#### Scenario: The runner drafts via the real adapter

- **WHEN** a mining run on the runner has `SUGGESTER_CMD=python3 scripts/aoai-suggester.py` and a recurring unflagged shape is mined
- **THEN** the adapter drafts a candidate from the masked signature, assigns the next free cost-band id from `CostRules.cs`, and the candidate passes the fail-closed validation gate before any branch is pushed

#### Scenario: A drafter failure degrades to green

- **WHEN** the suggester exits nonzero (auth, network, or an invalid draft)
- **THEN** `run-mining.sh` logs a skip line to the job summary and exits 0 (calibration has already run), and no pull request is opened
