## Why

`kuskus-report.yml` targets `runs-on: [self-hosted, kuskus]`, but no such runner exists — the
calibration/mining pipeline cannot actually run. The runner needs **line-of-sight to the internal
Kuskus ADX cluster** and a **managed identity** granted read on the `Kuskus` database; a
GitHub-hosted runner can do neither. Because the job is aperiodic (weekly cron + dispatch), a
persistent runner would idle-burn cost and need patching. This change provisions the runner as
**ephemeral, scale-to-zero serverless compute** via infrastructure-as-code.

## What Changes

- Add **`infra/terraform/`**: an `azurerm`/`azapi` stack (subscription + region as variables)
  provisioning a resource group, a **user-assigned managed identity**, an **ACR** (runner image),
  a **Container Apps environment**, a **Container App Job** (Consumption) with a KEDA
  **`github-runner`** event scale rule (label `kuskus`, `--ephemeral` runner), a small **Storage
  account** (`tfstate` + `kuskus-state` containers), and role assignments. Remote state lives in the
  storage account (`azurerm` backend); a one-time `az` command bootstraps that account.
- Add **`infra/runner-image/Dockerfile`**: the ephemeral runner image = the GitHub Actions runner
  agent + `az`, `python3` + `azure-kusto-data`, `gh`, `jq` (no .NET SDK).
- **Restructure `kuskus-report.yml`**: merge the two jobs (`calibrate`, `mine`) into **one** job
  (single corpus fetch, single watermark advance, shared in-container scratch); wrap the fetch with
  **durable-watermark sync** (`az storage blob download`/`upload` around the fetch on the
  `kuskus-state` container); obtain the scanner via **`gh release download kql-guard-linux-x64`**
  (no build step).
- **Auth**: a **GitHub App** (scoped `administration:write` + `actions:read`) drives the KEDA scaler
  and the ephemeral runner registration; its private key is a **Container App secret**. PR-open keeps
  using the workflow job's built-in `GITHUB_TOKEN`.
- **Document the one out-of-band step**: the MI's read on Kuskus is a
  `.add database Kuskus viewers ('aadapp=<mi-client-id>')` request to the Kuskus team — Terraform
  cannot grant it (the cluster is not ARM-managed by this subscription).

## Capabilities

### New Capabilities
- `runner-infra`: an ephemeral, scale-to-zero self-hosted GitHub Actions runner (Azure Container App
  Job + KEDA) with least-privilege Kuskus access, provisioned by Terraform, that executes the Kuskus
  calibration/mining pipeline and discards its filesystem each run.

## Impact

- **Code**: no binary or script runtime change; a new `infra/` tree + a `kuskus-report.yml`
  restructure. The scanner and `azure-kusto-data` come from the release/runner-image, not the repo
  build.
- **Cost**: pay-per-run compute (scale-to-zero) + a Basic ACR + a small LRS storage account;
  effectively free at idle.
- **Security**: the MI is viewer-only on one database; the GitHub App is repo-scoped; PR-open uses
  the job token; secrets are Container App secrets (no repo secrets, no Key Vault yet); subscription
  and identity ids are Terraform variables, never committed. The ephemeral filesystem means the
  corpus never persists past a run.
- **Cluster**: starts on the non-confidential `kuskushead` (query text mostly redacted →
  calibration-first); flip `KUSKUS_CLUSTER` to `kuskusheadconf` when confidential access lands.
- **Out-of-band**: one Kuskus viewer-grant request (the "takes time" bit).
- **Depends on**: `kuskus-corpus-fetch` (the real fetch this runner executes).
