## ADDED Requirements

### Requirement: Multi-mode self-contained action
The action SHALL run kql-guard on a fresh runner without a pre-existing build, selecting the install path via a `mode` input of `download` (default), `docker`, or `prebuilt`.

#### Scenario: Download mode on a supported runner
- **WHEN** the action runs with `mode: download` on linux-x64, linux-arm64, osx-arm64, or win-x64
- **THEN** it fetches the matching release asset, runs it, and produces SARIF

#### Scenario: Docker mode
- **WHEN** the action runs with `mode: docker`
- **THEN** it runs `ghcr.io/microsoft/kql-guard:<version>` against the workspace and produces SARIF

#### Scenario: Prebuilt mode
- **WHEN** the action runs with `mode: prebuilt` and a locally-built binary exists
- **THEN** it runs that binary and produces SARIF

#### Scenario: Unsupported runner under download
- **WHEN** `mode: download` runs on a runner with no matching asset
- **THEN** the step fails with a message naming the os/arch and pointing at `mode: docker`

### Requirement: Stable input and output contract
The action SHALL expose typed inputs `path`, `format`, `max-cost`, `schema`, plus `version`, `working-directory`, `fail-on-violations`, and a raw `args` passthrough, and SHALL set outputs `sarif-file` and `exit-code`.

#### Scenario: Consumer gates downstream (default)
- **WHEN** the scan reports violations (CLI exit 1) and `fail-on-violations` is `false`
- **THEN** the action sets `exit-code: 1` and does not itself fail the job

#### Scenario: Action gates directly
- **WHEN** the scan reports violations (CLI exit 1) and `fail-on-violations` is `true`
- **THEN** the action step fails the job

#### Scenario: Usage error surfaces
- **WHEN** the CLI exits 2 (usage error)
- **THEN** the action step fails loudly regardless of `fail-on-violations`

### Requirement: Marketplace readiness
The action SHALL include a `branding` block and a `version`-pinnable download/image so it can be published to and consumed from the GitHub Actions Marketplace.

#### Scenario: Pinned version
- **WHEN** a consumer sets `version` to a release tag
- **THEN** `download` and `docker` modes use that exact release/image tag

### Requirement: Cross-architecture binaries
The release build SHALL produce a `linux-arm64` asset in addition to linux-x64, osx-arm64, and win-x64.

#### Scenario: linux-arm64 asset exists
- **WHEN** a `v*` tag is pushed
- **THEN** the release includes `kql-guard-linux-arm64`
