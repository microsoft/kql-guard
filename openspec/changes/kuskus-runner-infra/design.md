# Design — Kuskus runner infra

## Context

`kuskus-report.yml` exists and targets `runs-on: [self-hosted, kuskus]`, but nothing provides that
runner. It must reach the internal Kuskus ADX cluster (`kuskushead.westeurope`, db `Kuskus`) with a
managed identity — GitHub-hosted runners cannot. The job is aperiodic (weekly cron + dispatch), so
the compute should cost nothing at idle. The corpus (query text) must never persist past a run
(trust boundary). This change provisions that runner as ephemeral serverless compute via IaC and
adapts the workflow to the ephemeral model. The fetch it runs is `kuskus-corpus-fetch`.

## Topology

```
GitHub workflow (kuskus-report.yml — weekly cron / dispatch)
   └─ job runs-on: [self-hosted, kuskus]        ← queued, no runner online
        │  KEDA github-runner scaler (polls the Actions queue with the PAT)
        ▼
Azure Container App Job (Consumption, scale-to-zero)
   • pulls the runner image from ACR
   • user-assigned Managed Identity ── AAD ──▶ kuskushead.westeurope / Kuskus (viewer)
   • one --ephemeral runner: checkout → watermark-in → fetch → calibrate → mine
        → open PRs → watermark-out → exit
   • fresh filesystem each run; corpus never persists
```

## Decisions

**1. Ephemeral, scale-to-zero: Azure Container App Job + KEDA `github-runner`.** Container App Jobs
run a container to completion on a KEDA event and scale to zero between runs — the exact fit for an
aperiodic weekly job (canonical Microsoft pattern: `az containerapp job create --trigger-type Event`
with a `github-runner` scale rule; the runner registers `--ephemeral`, runs one job, terminates).
Rejected: **ARC on AKS** (a 24/7 cluster to patch for a weekly job); a **persistent VM** (idle cost +
OS lifecycle); **VMSS** (overkill). Scale-to-zero means ~no idle cost and no compute to maintain.

**2. Network: public endpoint, no VNet.** `kuskushead` is reachable by any AAD-authenticated
principal — no IP allow-list, no private endpoint (confirmed with the operator) — so the runner needs
only outbound internet + the MI. No VNet injection, NAT gateway, or private DNS. Upgrade path (the one
trigger): if the cluster later restricts by IP, add a VNet-injected environment + a NAT gateway for a
static egress IP, or a private endpoint.

**3. Identity split — two identities, each least-privilege.**
- **Azure user-assigned MI**, attached to the Container App Job → AAD token for Kusto. Granted
  **viewer** on `Kuskus` only.
- **GitHub PAT** (`repo` scope, or fine-grained repo Administration RW + Actions RO + Metadata RO) →
  the KEDA scaler's queue poll + the ephemeral runner registration. Stored as a Container App secret.
- **PR-open** uses the workflow job's built-in `GITHUB_TOKEN` (`kuskus-report.yml` already declares
  `pull-requests: write`) — no third credential.

> **2026-07-19 pivot — GitHub App → PAT.** Originally a GitHub App (no expiry, finer scope). But
> installing an App on the `microsoft` org needs org-owner approval, which stalled indefinitely. A
> capability probe then **proved repo-level self-hosted runners are already permitted on
> `microsoft/kql-guard`** (a repo runner-registration-token mint succeeded with repo admin), so a
> plain `repo`-scoped PAT registers the runner and drives the scaler with no org approval. Tradeoff we
> accept: the PAT expires (rotation toil) and an *ephemeral* runner re-registers each run, so the PAT
> owner must retain repo admin at run time. If admin is non-persistent (PIM), the documented fallback
> is a **persistent-VM classic runner** — registered once while elevated, it survives later lapses;
> the workflow (`runs-on: [self-hosted, kuskus]`) is unchanged either way.

**4. Runner image: lean, no .NET SDK.** Base = `myoung34/github-runner` (it wraps the official Actions
runner and handles PAT auth + `--ephemeral` registration from `ACCESS_TOKEN`, so we don't hand-roll
the registration-token dance); add `az`, `python3` +
`azure-kusto-data`, `gh`, `jq`. The scanner is pulled at job time via
`gh release download kql-guard-linux-x64` (`release.yml` already publishes it), so the image needs no
.NET SDK and no rebuild when kql-guard changes — and calibration/mining run against the **shipped**
rules (arguably more correct than HEAD). Upgrade path: add a build step (needs the SDK) only if
HEAD-rule calibration is wanted.

**5. Single pipeline job (merge `calibrate` + `mine`).** On ephemeral runners each job is a fresh
container, so the current two-job workflow would fetch the corpus twice and race the watermark
(whichever advances first starves the other). Merge into one job: checkout → watermark-in → fetch
(once) → calibrate → mine → open PRs → watermark-out → exit. One fetch, one window, one watermark
advance, shared in-container `scratch/` discarded on exit. Cost: a calibrate failure now blocks mine
— acceptable (a bad corpus/run should stop both); per-step `set -e` still gives granular failure.

**6. Durable watermark via blob (not runner-local).** The ephemeral container has no persistent disk,
so the fetch's runner-local `watermark.txt` (corpus-fetch D5/D6) would not survive between weekly
runs. Keep `fetch_corpus.py` file-based and pure (unit-testable); the **workflow** provides
durability: `az storage blob download` the watermark into `KUSKUS_STATE_DIR` before fetch, and
`az storage blob upload` it back **on fetch-step success** (`kuskus-state` container,
MI-authenticated). The fetch still advances the local file only on a fully-written corpus, and the
upload is gated on that step's success, preserving fail-closed semantics. This keeps the
boundary-critical code storage-SDK-free and testable; durability is two `az` lines.

**7. IaC: Terraform, remote state, nothing hardcoded.** `azurerm` provider only — the Container App
Job, KEDA `github-runner` scale rule, ACR, storage, MI and role assignments are all native in
azurerm 4.x, so the originally-planned `azapi` would be dead config and is dropped. Subscription
id, region, MI client-id, GitHub owner/repo, and the GitHub PAT are variables (CI secrets / tfvars),
never committed. Remote state lives in the `tfstate` container (`azurerm` backend); the state storage
account is the one chicken-and-egg — created once by a documented `az storage account create` (a
bootstrap module would be more code than the problem). Check = `terraform fmt -check` + `validate` +
`plan`.

**8. What Terraform cannot do: the Kuskus grant.** `kuskushead` is an internal Microsoft cluster not
ARM-managed by this subscription, so `azurerm_kusto_database_principal_assignment` does not apply. The
MI's viewer grant is an out-of-band request to the Kuskus team:
`.add database Kuskus viewers ('aadapp=<mi-client-id>;<tenant>')`. Documented in the runner setup
notes; the pipeline fails closed (auth / getschema) until it lands.

## Components (Terraform)

| Resource | Purpose |
|---|---|
| Resource group | holds everything |
| User-assigned MI | Kusto auth (viewer on `Kuskus`, granted out-of-band) |
| ACR (Basic) | runner image registry |
| Storage account (LRS) | `tfstate` (remote state) + `kuskus-state` (watermark blob) |
| Log Analytics workspace | container logs for the unattended job (assert "no query text in logs") |
| Container Apps environment | Consumption, no VNet |
| Container App Job | KEDA `github-runner` event trigger, `--ephemeral` runner, MI attached, image from ACR, GitHub PAT as a secret |
| Role assignments | AcrPull (MI → ACR); Storage Blob Data Contributor (MI → `kuskus-state`) |

## Layout

```
infra/
  terraform/     main.tf variables.tf providers.tf backend.tf outputs.tf
  runner-image/  Dockerfile
  README.md      # state bootstrap, Kuskus viewer-grant request, GitHub PAT setup, apply + build steps
```

## Testability / verification

- `terraform fmt -check` + `terraform validate` are the offline runnable checks; `terraform plan`
  against the subscription is the integration check (needs Azure creds).
- The Dockerfile is verified by a build (`az acr build` / local `docker build`) asserting the
  toolchain is present: `python3 -c 'import azure.kusto.data'`, `az version`, `gh --version`, and the
  runner agent.
- End-to-end (documented, not in CI — needs the live grant): a manual `workflow_dispatch` of
  `kuskus-report.yml` → KEDA starts a job → the ephemeral runner picks it up → the getschema guard +
  fetch + calibrate/mine run → the watermark advances in the blob → no query text appears in any log.

## Config

| Var / secret | Meaning |
|---|---|
| `subscription_id` | Terraform var (the target subscription) |
| `location` | `westeurope` (co-located with the cluster) |
| `github_owner` / `github_repo` | `microsoft` / `kql-guard` |
| GitHub PAT (`repo` scope) | KEDA scaler + runner registration (Container App secret) |
| `KUSKUS_CLUSTER` (job env) | `https://kuskushead.westeurope.kusto.windows.net` (flip to `…conf` later) |
| `KUSKUS_STATE_DIR` (job env) | local dir synced to/from the `kuskus-state` blob |

## Skipped (YAGNI — each with its trigger)

- **VNet / NAT / private endpoint** — public AAD-only; add if the cluster restricts by IP.
- **Key Vault** — Container App secrets suffice; add if secret rotation/sharing demands.
- **AKS / ARC** — a weekly job doesn't warrant a cluster.
- **Scanner build step** — download the shipped binary; add if HEAD-rule calibration is wanted.
- **Persistent compute** — scale-to-zero fits an aperiodic job.
- **Bootstrap TF module** — one documented `az` command is smaller than the module.
