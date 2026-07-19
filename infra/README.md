# Kuskus runner infrastructure

Provisions the persistent self-hosted runner that powers `.github/workflows/kuskus-report.yml`.
It is a small always-on **Azure VM**, registered once as a classic self-hosted runner (label
`kuskus`): GitHub dispatches each queued job straight to it, and it runs the calibration/mining
pipeline against the Kuskus ADX cluster via an attached managed identity. Registering once — with a
one-time token, no durable GitHub secret — sidesteps the org's 8-day classic-PAT SSO cap and survives
later repo-admin lapses. The corpus never persists past a run (the workflow scrubs `scratch/`).

See `openspec/changes/kuskus-runner-infra/` for the design and decisions.

```
infra/
  terraform/     # the Azure resources (azurerm): MI, storage, networking, the runner VM
```

## What Terraform provisions

Resource group, user-assigned managed identity, storage account (`tfstate` + `kuskus-state`
containers), a VNet/subnet/NSG (deny-all-inbound) + Standard public IP (egress) + NIC, and the Ubuntu
runner VM (`Standard_B2s`) whose cloud-init installs the toolchain and registers the runner. Role
assignment: MI → `Storage Blob Data Contributor` on the `kuskus-state` container (plus, out-of-band,
viewer on the Kuskus DB).

## Prerequisites

- `az` (logged in: `az login`), `gh` (logged in, to mint the registration token), `terraform` >= 1.5.
- Owner/Contributor + User Access Administrator on the target subscription
  **Kusto_PM_Experiments** (`92288740-be22-448e-b3a1-697c0535e005`) — role assignments require it.
- Repo admin on `microsoft/kql-guard` at apply time (to mint the runner registration token).
- An SSH public key (break-glass) and the Kuskus viewer grant (below).

## Operator checklist

Top to bottom; each item links to its section. Everything before §5 is one-time.

- [ ] **Login + target subscription** — `az login && az account set --subscription 92288740-be22-448e-b3a1-697c0535e005`
- [ ] **§1 Bootstrap remote state** — run the block; keep the printed `STATE_ACCOUNT`.
- [ ] **§2 Runner registration token** — mint a one-time token (valid ~1h); it's consumed at first boot.
- [ ] **§3 `terraform apply`** — `init -backend-config=...` then `apply` (token + SSH key via `TF_VAR_*`).
- [ ] **§4 Kuskus grant** — send `terraform output -raw kuskus_viewer_grant_command` to the Kuskus team.
- [ ] **§5 Smoke** — dispatch (dry run); verify the runner picks it up, the watermark advances, no query text in any log.

## 1. One-time remote-state bootstrap

The state backend can't create its own storage, so create it once. Copy-paste as-is —
`STATE_ACCOUNT` is auto-generated globally-unique, and the `tfstate` container is created with the
account key (the same auth the `azurerm` backend uses), which also avoids the RBAC-propagation delay
that `--auth-mode login` hits on a brand-new account:

```bash
az account set --subscription 92288740-be22-448e-b3a1-697c0535e005

STATE_ACCOUNT="kuskustfstate$(openssl rand -hex 4)"   # 3–24 lowercase alphanumeric

az group create -n kuskus-runner-tfstate -l westeurope
az storage account create -n "$STATE_ACCOUNT" -g kuskus-runner-tfstate -l westeurope \
  --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false
KEY=$(az storage account keys list -n "$STATE_ACCOUNT" -g kuskus-runner-tfstate \
  --query '[0].value' -o tsv)
az storage container create -n tfstate --account-name "$STATE_ACCOUNT" --account-key "$KEY"

echo "STATE_ACCOUNT=$STATE_ACCOUNT"
echo "init:  terraform init -backend-config=\"storage_account_name=$STATE_ACCOUNT\""
```

## 2. Runner registration token (one-time, consumed at first boot)

Repo-level self-hosted runners are permitted on `microsoft/kql-guard` (verified: a repo
registration-token mint succeeds with repo admin). The VM registers **once** with a one-time token —
no durable PAT or GitHub App, so the org's 8-day classic-PAT SSO cap doesn't apply. Mint it right
before `apply` (valid ~1 hour):

```bash
gh api -X POST repos/microsoft/kql-guard/actions/runners/registration-token --jq .token
```

Pass it as `TF_VAR_runner_registration_token` (step 3). It's consumed on first boot; the runner then
holds its own credential. Recreate the VM ⇒ mint a fresh token. PR-opening uses the workflow's
built-in `GITHUB_TOKEN` (the workflow declares `pull-requests: write`), so no other GitHub credential
is needed.

> **Why a VM, not scale-to-zero.** microsoft caps classic PATs at an 8-day SSO-authorization max, so
> the ephemeral Container-App-Job design (whose KEDA scaler needs a durable PAT) would require weekly
> rotation. A persistent VM registered once needs no durable secret. Tradeoff: a small always-on VM
> (~30 USD/mo) vs. no idle cost. `ponytail:` deallocate-between-weekly-runs is the upgrade path if
> cost matters (needs a scheduler; not built).

## 3. Apply Terraform

```bash
cd infra/terraform
terraform init -backend-config="storage_account_name=$STATE_ACCOUNT"  # value printed by step 1

# Inputs via env (never commit tfvars):
export TF_VAR_subscription_id=92288740-be22-448e-b3a1-697c0535e005
export TF_VAR_runner_registration_token=$(gh api -X POST \
  repos/microsoft/kql-guard/actions/runners/registration-token --jq .token)   # step 2 (fresh)
export TF_VAR_admin_ssh_public_key="$(cat ~/.ssh/id_rsa.pub)"                  # break-glass only

terraform plan
terraform apply
```

Offline schema check (no Azure creds): `terraform init -backend=false && terraform validate`.

Note `terraform output`:

- `mi_client_id` — for the Kusto grant (step 4).
- `kuskus_viewer_grant_command` — the ready-to-run grant for step 4.
- `vm_name` — the runner VM (Serial Console / Bastion for break-glass; inbound SSH is NSG-denied).

After apply, cloud-init needs a few minutes to install the toolchain and register the runner; confirm
it shows **Online** under repo Settings → Actions → Runners (label `kuskus`).

## 4. Grant the MI viewer on Kuskus (out-of-band)

`kuskushead` is an internal cluster not ARM-managed by this subscription, so Terraform can't grant it.
Send this to the Kuskus team (from `terraform output -raw kuskus_viewer_grant_command`):

```kusto
.add database Kuskus viewers ('aadapp=<mi-client-id>;<tenant-id>')
```

Until it lands, the pipeline fails closed at auth / the `getschema` guard — no partial output.

## 5. First-run smoke (manual, not in CI)

Needs the grant from step 4 and the runner **Online** (step 3).

1. Actions → **Kuskus calibration report** → **Run workflow** (leave `apply` off for a dry run).
2. The persistent runner picks up the job (no cold start — it's already Online).
3. Expect: `getschema` guard passes → a bounded window is pulled → calibration + mining reports
   appear in the job summary → the watermark advances in the `kuskus-state` blob.
4. Confirm **no query text** appears in any log (only aggregate counts / abstracted signatures), and
   that the final scrub step cleared `scratch/`.
5. Re-run with `apply: true` once the dry run looks right to open the mechanical PRs.

Offline path (no cluster): dispatch with `corpus_path` pointing at a dir that contains `.kql` files
and a `manifest.json` — the ADX fetch and watermark sync are skipped.

## Teardown

`terraform destroy` (from `infra/terraform`) removes everything except the bootstrap state RG/account
(delete those manually). The self-hosted runner entry lingers in GitHub as **Offline** once the VM is
gone — remove it under repo Settings → Actions → Runners (it also auto-cleans after 14 days idle).
