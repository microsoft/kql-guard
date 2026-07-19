## ADDED Requirements

### Requirement: Ephemeral scale-to-zero runner

The pipeline SHALL execute on a self-hosted GitHub Actions runner provisioned as event-triggered,
scale-to-zero serverless compute (an Azure Container App Job scaled by KEDA on queued jobs labeled
`kuskus`). Each execution SHALL register an ephemeral runner, process exactly one workflow job, and be
destroyed with its filesystem on completion, so no corpus persists between runs and no compute is
billed at idle.

#### Scenario: A queued job starts and disposes a runner

- **WHEN** a `kuskus-report.yml` job labeled `kuskus` is queued and no runner is online
- **THEN** the KEDA scaler starts one Container App Job execution that registers an ephemeral runner,
  runs the job, and terminates with its filesystem discarded and no runner left online

### Requirement: Least-privilege identities

Kuskus access SHALL use a user-assigned managed identity granted read (viewer) on the `Kuskus`
database only. Runner registration and scaler queue-polling SHALL use a GitHub App scoped to runner
administration and Actions read. Opening pull requests SHALL use the workflow's built-in job token. No
long-lived personal access token and no repository-stored cluster secret SHALL be required.

#### Scenario: Identities are scoped and separated

- **WHEN** the runner fetches telemetry and opens a PR
- **THEN** telemetry auth uses the managed identity (viewer on `Kuskus`), PR creation uses the job's
  `GITHUB_TOKEN`, and neither uses a broad or long-lived secret

### Requirement: Durable watermark across ephemeral runs

The fetch watermark SHALL persist in durable storage (a blob) so a run resumes where the previous one
ended despite the runner having no persistent disk. The workflow SHALL restore the watermark before
fetching and persist it only after a successful fetch; the fetch script SHALL remain file-based and
unaware of the storage backend.

#### Scenario: Watermark survives runner disposal

- **WHEN** a run completes and advances the watermark, then the runner is destroyed and a later run
  starts on a fresh runner
- **THEN** the later run restores the advanced watermark from the blob and fetches only newer rows

#### Scenario: Failed fetch does not persist the watermark

- **WHEN** the fetch step fails
- **THEN** the watermark blob is not updated and the next run re-pulls the same window

### Requirement: Single-fetch pipeline run

A pipeline run SHALL fetch the corpus once and run both calibration and mining against that single
window, so the two consumers cannot double-fetch or race the watermark.

#### Scenario: One fetch feeds calibration and mining

- **WHEN** a pipeline run executes
- **THEN** the corpus is fetched exactly once, both calibration and mining consume the same
  `scratch/` and `manifest.json`, and the watermark advances once

### Requirement: Reproducible infrastructure as code

The runner infrastructure SHALL be defined as Terraform with remote state and no hardcoded
subscription, tenant, or secret values (these are variables sourced from CI secrets or tfvars). The
one grant Terraform cannot perform — the managed identity's read on the internal Kuskus cluster —
SHALL be documented as an out-of-band request.

#### Scenario: Config carries no secrets

- **WHEN** the Terraform is committed
- **THEN** it contains no subscription id, tenant id, or secret literal, and `terraform validate`
  passes with those supplied as variables
