## Why

`kuskus-report.yml` targets `runs-on: [self-hosted, kuskus]`, but no such runner exists — the
calibration/mining pipeline cannot actually run. The runner needs **line-of-sight to the internal
Kuskus ADX cluster** and a **managed identity** granted read on the `Kuskus` database; a
GitHub-hosted runner can do neither. Because the job is aperiodic (weekly cron + dispatch), the
runner is a **persistent self-hosted VM registered once** (the `microsoft` org's 8-day classic-PAT SSO
cap rules out the scale-to-zero KEDA design, which would need a durable credential — see design
decision 1). This change provisions that runner via infrastructure-as-code.

## What Changes

- Add **`infra/terraform/`**: an `azurerm` stack (subscription + region as variables) provisioning a
  resource group, a **user-assigned managed identity**, a small **Storage account** (`tfstate` +
  `kuskus-state` containers), an **egress-only VNet/subnet/NSG** (deny all inbound) + Standard public
  IP + NIC, and an **Ubuntu VM** (`Standard_B2s`) whose **cloud-init** installs the toolchain and
  registers the runner once (label `kuskus`, systemd service). Role assignment: MI → Storage Blob Data
  Contributor on `kuskus-state`. Remote state lives in the storage account (`azurerm` backend); a
  one-time `az` command bootstraps that account.
- Add **`infra/terraform/runner-init.sh.tftpl`**: the VM cloud-init = install the GitHub Actions runner
  agent + `az`, `python3` + `azure-kusto-data`, `gh`, `jq`, and the **.NET SDK** (NativeAOT prereqs
  `clang` + `zlib1g-dev`) so the runner builds kql-guard from source; write the `KUSKUS_*` job
  `.env`; register the runner with a one-time token.
- **Restructure `kuskus-report.yml`**: merge the two jobs (`calibrate`, `mine`) into **one** job
  (single corpus fetch, single watermark advance, shared scratch); wrap the fetch with
  **durable-watermark sync** (`az storage blob download`/`upload` around the fetch on the
  `kuskus-state` container); **build the scanner from HEAD** (`dotnet build -c Debug`, so it carries
  `--shapes` and matches the source under review — and `validate-candidate.sh` can compile a drafted
  rule); add a final **`if: always()` scrub** of `scratch/` (the VM workspace is reused, so the
  corpus must be deleted explicitly to honor the trust boundary).
- **Auth**: a **one-time runner registration token** (minted at apply, consumed at first boot) — no
  durable GitHub secret on the VM. (History: GitHub App → PAT → persistent VM; the org blocks a durable
  App/PAT, see design decision 1.) PR-open keeps using the workflow job's built-in `GITHUB_TOKEN`.
- **Document the one out-of-band step**: the MI's read on Kuskus is a
  `.add database Kuskus viewers ('aadapp=<mi-client-id>')` request to the Kuskus team — Terraform
  cannot grant it (the cluster is not ARM-managed by this subscription).

## Capabilities

### New Capabilities
- `runner-infra`: a persistent self-hosted GitHub Actions runner (a register-once Azure VM) with
  least-privilege Kuskus access, provisioned by Terraform, that executes the Kuskus calibration/mining
  pipeline and scrubs the corpus at the end of each run.

## Impact

- **Code**: no binary or script runtime change; a new `infra/` tree + a `kuskus-report.yml`
  restructure. The scanner and `azure-kusto-data` come from the release / VM cloud-init, not the repo
  build.
- **Cost**: a small always-on VM (`Standard_B2s`, ~30 USD/mo) + a Standard public IP + a small LRS
  storage account. (Upgrade path: deallocate the VM between weekly runs if idle cost matters.)
- **Security**: the MI is viewer-only on one database; the VM has **no durable GitHub secret** (a
  one-time registration token, consumed at boot); PR-open uses the job token; inbound is NSG-denied;
  subscription and identity ids are Terraform variables, never committed. The end-of-run scrub means
  the corpus never persists past a run.
- **Cluster**: starts on the non-confidential `kuskushead` (query text mostly redacted →
  calibration-first); flip `KUSKUS_CLUSTER` to `kuskusheadconf` when confidential access lands.
- **Out-of-band**: one Kuskus viewer-grant request (the "takes time" bit).
- **Depends on**: `kuskus-corpus-fetch` (the real fetch this runner executes).
