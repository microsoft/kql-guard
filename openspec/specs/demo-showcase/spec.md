# demo-showcase Specification

## Purpose
TBD - created by archiving change demo-showcase-pr. Update Purpose after archive.
## Requirements
### Requirement: Demo detection fixture
The repo SHALL include a `demo/` directory whose single KQL file triggers every feature class, used only for stakeholder demos and CI showcase, never imported by the product.

#### Scenario: One file, five findings
- **WHEN** kql-guard scans `demo/detections/SuspiciousSignin.kql`
- **THEN** it reports a formatter diff, ≥2 cost rules, a non-zero cost score, and (with `--schema demo/schema.json`) a KQL101 unknown-column error

### Requirement: PR showcases features via CI
The CI workflow SHALL run kql-guard over `demo/` so an open PR shows inline SARIF alerts, a failing `--max-cost` gate, a KQL101 schema error, and a `fmt --check` diff.

#### Scenario: Reviewer opens the demo PR
- **WHEN** the demo PR is open against microsoft/kql-guard
- **THEN** code scanning annotates the changed lines and the cost-gate step fails red while other features report green

