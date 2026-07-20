## ADDED Requirements

### Requirement: Persistent register-once runner

The pipeline SHALL execute on a persistent self-hosted GitHub Actions runner (an always-on Azure VM
registered once, label `kuskus`) to which GitHub dispatches queued jobs directly. Registration SHALL
use a one-time token consumed at first boot, so no durable GitHub secret persists on the runner.
Because the runner's workspace is reused across runs, the workflow SHALL delete the corpus (`scratch/`)
at the end of every run so no query text persists past a run.

#### Scenario: A queued job runs on the standing runner

- **WHEN** a `kuskus-report.yml` job labeled `kuskus` is queued
- **THEN** the already-registered runner picks it up (no cold start), runs the job, and a final
  always-run step deletes `scratch/` so the corpus does not persist to the next run

### Requirement: Least-privilege identities

Kuskus access SHALL use a user-assigned managed identity granted read (viewer) on the `Kuskus`
database only. Runner registration SHALL use a one-time GitHub registration token, consumed at first
boot; the runner thereafter holds its own credential and no durable GitHub secret is stored. Opening
pull requests SHALL use the workflow's built-in job token. No cluster secret SHALL be stored in the
repository.

#### Scenario: Identities are scoped and separated

- **WHEN** the runner fetches telemetry and opens a PR
- **THEN** telemetry auth uses the managed identity (viewer on `Kuskus`), PR creation uses the job's
  `GITHUB_TOKEN`, and neither uses a broad or long-lived secret

### Requirement: Durable watermark in blob storage

The fetch watermark SHALL persist in durable storage (a blob) so a run resumes where the previous one
ended and survives VM re-creation. The workflow SHALL restore the watermark before fetching and persist
it only after a successful fetch; the fetch script SHALL remain file-based and unaware of the storage
backend.

#### Scenario: Watermark survives VM re-creation

- **WHEN** a run completes and advances the watermark, then the VM is recreated and a later run starts
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
