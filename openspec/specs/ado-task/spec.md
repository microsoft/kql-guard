# ado-task Specification

## Purpose
TBD - created by archiving change ado-task. Update Purpose after archive.
## Requirements
### Requirement: Multi-mode Azure DevOps task

The system SHALL provide a packaged Azure DevOps pipeline task `KqlGuard` that
runs kql-guard on a fresh agent without a pre-existing build, selecting the
acquisition path via a `mode` input of `download` (default), `docker`, or
`prebuilt`, with the same behavior as the GitHub Action.

#### Scenario: Download mode on a supported agent

- **WHEN** the task runs with `mode: download` on linux-x64, linux-arm64, osx-arm64, or win-x64
- **THEN** it fetches the matching release asset, runs it, and produces SARIF

#### Scenario: Docker mode

- **WHEN** the task runs with `mode: docker`
- **THEN** it runs `ghcr.io/microsoft/kql-guard:<version>` against the workspace and produces SARIF

#### Scenario: Prebuilt mode

- **WHEN** the task runs with `mode: prebuilt` and a locally-built binary exists
- **THEN** it runs that binary and produces SARIF

#### Scenario: Unsupported agent under download

- **WHEN** `mode: download` runs on an agent with no matching asset
- **THEN** the task fails with a message naming the os/arch and pointing at `mode: docker`

### Requirement: Stable input and output contract

The task SHALL expose typed inputs `path`, `mode`, `version`, `format`,
`maxCost`, `schema`, `args`, `workingDirectory`, `failOnViolations`, and
`prebuiltPath` mirroring the GitHub Action, plus two Azure DevOps toggles
`publishSarifArtifact` (default `true`) and `logIssues` (default `true`), and
SHALL set outputs `exitCode` and `sarifFile`.

#### Scenario: Defaults require only a path

- **WHEN** the task runs with only `path` set and all other inputs at their defaults
- **THEN** it runs `mode: download`, `version: latest`, `format: sarif`, and sets `exitCode` and `sarifFile`

#### Scenario: Raw args passthrough

- **WHEN** the task is given a raw `args` string
- **THEN** those arguments are appended to the kql-guard invocation unchanged

### Requirement: SARIF surfacing in Azure DevOps

Because Azure DevOps has no native SARIF ingestion, the task SHALL surface
findings two independently-toggleable ways: by publishing the SARIF as a build
artifact named `CodeAnalysisLogs` when `publishSarifArtifact` is true, and by
emitting one `##vso[task.logissue …]` per SARIF result when `logIssues` is true.

#### Scenario: SARIF published for the Scans tab

- **WHEN** the task completes a `format: sarif` run with `publishSarifArtifact: true`
- **THEN** the SARIF file is uploaded as an artifact named `CodeAnalysisLogs` that the SARIF SAST Scans Tab extension renders

#### Scenario: Findings logged inline

- **WHEN** the task completes a `format: sarif` run with `logIssues: true` and the SARIF contains results
- **THEN** the task emits one build issue per result with its severity, file, line, and column, so findings appear inline without any extra extension

#### Scenario: Surfacing toggles are independent

- **WHEN** `publishSarifArtifact` is false and `logIssues` is true
- **THEN** no `CodeAnalysisLogs` artifact is published but inline issues are still emitted

### Requirement: Exit-code gate mapped to task results

The task SHALL map the kql-guard exit code to an Azure DevOps task result,
preserving the GitHub Action's gate semantics: CLI exit `2` fails the task
regardless of `failOnViolations`; exit `1` fails the task only when
`failOnViolations` is true and otherwise completes with issues; exit `0`
succeeds.

#### Scenario: Advisory violations (default)

- **WHEN** the scan reports violations (CLI exit 1) and `failOnViolations` is `false`
- **THEN** the task sets `exitCode: 1`, completes as SucceededWithIssues, and does not fail the pipeline

#### Scenario: Task gates directly

- **WHEN** the scan reports violations (CLI exit 1) and `failOnViolations` is `true`
- **THEN** the task result is Failed

#### Scenario: Usage error surfaces

- **WHEN** the CLI exits 2 (usage error)
- **THEN** the task result is Failed regardless of `failOnViolations`

### Requirement: Marketplace readiness

The task SHALL be packaged as an Azure DevOps extension with a
`vss-extension.json` manifest, an icon, and a versioned task definition so it can
be built into a `.vsix` and published to and consumed from the Azure DevOps
Marketplace as `KqlGuard@1`.

#### Scenario: Extension builds to a vsix

- **WHEN** the extension is built with `tfx extension create`
- **THEN** a `.vsix` is produced containing the `KqlGuard` task and its manifest

#### Scenario: Pinned version

- **WHEN** a consumer sets `version` to a release tag
- **THEN** `download` and `docker` modes use that exact release asset/image tag

