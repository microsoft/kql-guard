# Kuskus runner infrastructure

Provisions the ephemeral self-hosted runner that powers `.github/workflows/kuskus-report.yml`.
It is a scale-to-zero **Azure Container App Job**: KEDA's `github-runner` scaler watches the repo's
Actions queue and starts one replica per queued `kuskus` job; the replica registers an `--ephemeral`
runner, runs the calibration/mining pipeline against the Kuskus ADX cluster via a managed identity,
then exits. No idle cost, and the corpus never persists past a run (trust boundary).

See `openspec/changes/kuskus-runner-infra/` for the design and decisions.

```
infra/
  terraform/     # the Azure resources (azurerm)
  runner-image/  # the runner container image (Dockerfile)
```

## What Terraform provisions

Resource group, user-assigned managed identity, ACR (Basic), storage account (`tfstate` +
`kuskus-state` containers), Log Analytics workspace, a Container Apps environment, and the Container
App Job with the KEDA `github-runner` scale rule. Role assignments: MI → `AcrPull` on the ACR and
`Storage Blob Data Contributor` on the `kuskus-state` container.

## Prerequisites

- `az` (logged in: `az login`), `terraform` >= 1.5, and Docker or access to `az acr build`.
- Owner/Contributor + User Access Administrator on the target subscription
  (`56361900-da6a-4977-89a7-8e40f44b86f6`) — role assignments require it.
- A GitHub App (below) and the Kuskus viewer grant (below).

## 1. One-time remote-state bootstrap

The state backend can't create its own storage, so create it once (names must be globally unique):

```bash
az group create -n kuskus-runner-tfstate -l westeurope
az storage account create -n <STATE_ACCOUNT> -g kuskus-runner-tfstate -l westeurope \
  --sku Standard_LRS --min-tls-version TLS1_2
az storage container create -n tfstate --account-name <STATE_ACCOUNT> --auth-mode login
```

## 2. GitHub App (runner registration + KEDA scaler)

1. Create a GitHub App (org or personal). Disable Webhooks.
2. Repository permissions: **Actions: Read-only**, **Administration: Read & write**,
   **Metadata: Read-only**.
3. Generate a private key (`.pem`) and note the **App ID**.
4. Install the App on `microsoft/kql-guard`; note the **Installation ID** (in the installation URL).

The App authenticates both the KEDA scaler (queue poll) and the runner's ephemeral registration.
PR-opening uses the workflow's built-in `GITHUB_TOKEN` (the workflow declares `pull-requests: write`),
so no extra credential is needed there.

## 3. Apply Terraform

```bash
cd infra/terraform
terraform init -backend-config="storage_account_name=<STATE_ACCOUNT>"

# Secrets/ids via env (never commit tfvars):
export TF_VAR_subscription_id=56361900-da6a-4977-89a7-8e40f44b86f6
export TF_VAR_github_app_id=<APP_ID>
export TF_VAR_github_app_installation_id=<INSTALLATION_ID>
export TF_VAR_github_app_private_key="$(cat path/to/app.private-key.pem)"

terraform plan
terraform apply
```

Offline schema check (no Azure creds): `terraform init -backend=false && terraform validate`.

Note `terraform output`:

- `acr_name` / `acr_login_server` — for the image build (step 4).
- `mi_client_id` — for the Kusto grant (step 5).
- `kuskus_viewer_grant_command` — the ready-to-run grant for step 5.

## 4. Build + push the runner image

The image has no .NET SDK; the scanner binary is downloaded per run. Build straight into the ACR:

```bash
az acr build --registry $(terraform output -raw acr_name) \
  --image kuskus-runner:latest infra/runner-image
```

The Dockerfile self-checks its toolchain at build time (`import azure.kusto.data`, `az`, `gh`, `jq`).
`var.runner_image_tag` defaults to `latest`; pin a digest/tag for production if desired.

## 5. Grant the MI viewer on Kuskus (out-of-band)

`kuskushead` is an internal cluster not ARM-managed by this subscription, so Terraform can't grant it.
Send this to the Kuskus team (from `terraform output -raw kuskus_viewer_grant_command`):

```kusto
.add database Kuskus viewers ('aadapp=<mi-client-id>;<tenant-id>')
```

Until it lands, the pipeline fails closed at auth / the `getschema` guard — no partial output.

## 6. First-run smoke (manual, not in CI)

Needs the grant from step 5.

1. Actions → **Kuskus calibration report** → **Run workflow** (leave `apply` off for a dry run).
2. KEDA starts a Container App Job replica; the ephemeral runner picks up the job.
3. Expect: `getschema` guard passes → a bounded window is pulled → calibration + mining reports
   appear in the job summary → the watermark advances in the `kuskus-state` blob.
4. Confirm **no query text** appears in any log (only aggregate counts / abstracted signatures).
5. Re-run with `apply: true` once the dry run looks right to open the mechanical PRs.

Offline path (no cluster): dispatch with `corpus_path` pointing at a dir that contains `.kql` files
and a `manifest.json` — the ADX fetch and watermark sync are skipped.

## Teardown

`terraform destroy` (from `infra/terraform`) removes everything except the bootstrap state RG/account
(delete those manually) and the GitHub App (delete in GitHub).
