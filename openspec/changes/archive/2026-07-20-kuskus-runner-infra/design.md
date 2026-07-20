# Design — Kuskus runner infra

## Context

`kuskus-report.yml` exists and targets `runs-on: [self-hosted, kuskus]`, but nothing provides that
runner. It must reach the internal Kuskus ADX cluster (`kuskushead.westeurope`, db `Kuskus`) with a
managed identity — GitHub-hosted runners cannot. The job is aperiodic (weekly cron + dispatch). The
corpus (query text) must never persist past a run (trust boundary). This change provisions that runner
as a persistent self-hosted VM via IaC and adapts the workflow to it. The fetch it runs is
`kuskus-corpus-fetch`.

## Topology

```
GitHub workflow (kuskus-report.yml — weekly cron / dispatch)
   └─ job runs-on: [self-hosted, kuskus]
        │  GitHub dispatches straight to the already-registered runner (no scaler, no cold start)
        ▼
Azure VM (Standard_B2s, always-on) — registered ONCE as a classic self-hosted runner
   • cloud-init: install toolchain + write KUSKUS_* .env + config.sh (one-time token) + systemd svc
   • user-assigned Managed Identity ── AAD ──▶ kuskushead.westeurope / Kuskus (viewer)
   • per job: checkout → watermark-in → fetch → calibrate → mine → open PRs → watermark-out → scrub
   • workspace reused across runs; the workflow scrubs scratch/ so the corpus never persists
```

## Decisions

**1. Persistent VM classic runner (register once).** A small always-on Ubuntu VM (`Standard_B2s`),
registered ONCE as a classic self-hosted runner (label `kuskus`) via cloud-init using a one-time
registration token, then run as a systemd service. GitHub dispatches each queued job straight to it —
no scaler, no cold start.

> **2026-07-20 pivot — ephemeral Container App Job → persistent VM.** The original design was a
> scale-to-zero Azure Container App Job with a KEDA `github-runner` scaler (no idle cost). That needs a
> *durable* GitHub credential for the scaler's queue poll + per-run ephemeral registration. The
> `microsoft` org blocks both durable options: a GitHub App install needs org-owner approval (stalled
> indefinitely), and classic PATs are capped at an **8-day** SSO-authorization max — so the KEDA design
> would mean re-issuing the PAT (and updating the Azure secret) roughly weekly. A persistent VM
> registered once needs **no durable secret**: the one-time token is consumed at first boot and the
> runner then holds its own credential, surviving later repo-admin lapses. Tradeoff accepted: a small
> always-on VM (~30 USD/mo) instead of scale-to-zero. Still rejected: **ARC on AKS** (a cluster to
> patch for a weekly job); **VMSS** (overkill for one runner). Upgrade path if idle cost matters:
> deallocate the VM between weekly runs via a scheduled start/stop (needs an Automation runbook; not
> built).

**2. Network: egress-only, deny inbound.** `kuskushead` is reachable by any AAD-authenticated
principal (no IP allow-list, confirmed with the operator), and the runner only makes outbound calls
(GitHub long-poll, Kuskus, release download). So: a minimal VNet/subnet, an NSG that **denies all
inbound**, and a Standard public IP for guaranteed egress (cheaper than a NAT gateway for one VM).
Break-glass is via Serial Console / Bastion — no inbound SSH rule. Upgrade path: if the cluster later
restricts by IP, the Standard public IP already gives a stable egress address to allow-list (or swap
in a NAT gateway / private endpoint).

**3. Identity split — two identities, each least-privilege.**
- **Azure user-assigned MI**, attached to the VM → AAD token for Kusto. Granted **viewer** on
  `Kuskus` only.
- **GitHub one-time registration token** → registers the runner at first boot; consumed immediately,
  after which the runner holds its own credential. No durable GitHub secret lives on the box (see
  decision 1 for why not a durable PAT/App).
- **PR-open** uses the workflow job's built-in `GITHUB_TOKEN` (`kuskus-report.yml` already declares
  `pull-requests: write`) — no third credential.

**4. Toolchain via cloud-init, no image; .NET SDK for build-from-source.** The VM's cloud-init installs the
official Actions runner agent + `az`, `python3` + `azure-kusto-data` (pinned), `gh`, `jq`, and the **.NET
SDK** (via the official dotnet-install script; NativeAOT prereqs `clang` + `zlib1g-dev`) — the persistent-VM
equivalent of the old runner image (dropped with the Container App Job). The scanner is **built from HEAD**
at job time (`dotnet build -c Debug`), so calibration/mining run against the source under review — it carries
`--shapes` (which the shipped release predates), and `validate-candidate.sh` can COMPILE a drafted rule for
the over-report gate, which needs the SDK and the confidential corpus together (they coexist only here).
Trade-off vs. the earlier download-the-release design: a one-time SDK install + a ~1–2 min build per weekly
run, in exchange for HEAD-matching rules, `--shapes`, and a real compile/validate gate.

**5. Single pipeline job (merge `calibrate` + `mine`) + end-of-run scrub.** Two separate jobs would
fetch the corpus twice and race the watermark (whichever advances first starves the other). Merge into
one job: checkout → watermark-in → fetch (once) → calibrate → mine → open PRs → watermark-out. One
fetch, one window, one watermark advance. Because the VM's **workspace is reused** across runs (unlike
the old ephemeral container), a final `if: always()` step scrubs `scratch/` + the state dir so query
text never persists past a run — the trust boundary the ephemeral filesystem used to give for free.
Cost: a calibrate failure blocks mine — acceptable (a bad corpus/run should stop both); per-step
`set -e` still gives granular failure.

**6. Durable watermark via blob (not runner-local).** Even though the VM has a persistent disk, the
watermark lives in the `kuskus-state` blob so it survives VM re-creation and stays the single source
of truth. Keep `fetch_corpus.py` file-based and pure (unit-testable); the **workflow** provides
durability: `az storage blob download` the watermark into `KUSKUS_STATE_DIR` before fetch, and
`az storage blob upload` it back **on fetch-step success** (`kuskus-state` container,
MI-authenticated). The fetch still advances the local file only on a fully-written corpus, and the
upload is gated on that step's success, preserving fail-closed semantics. This keeps the
boundary-critical code storage-SDK-free and testable; durability is two `az` lines.

**7. IaC: Terraform, remote state, nothing hardcoded.** `azurerm` provider only — the VM, networking,
storage, MI and role assignment are all native in azurerm 4.x, so the originally-planned `azapi` would
be dead config and is dropped. Subscription id, region, MI client-id, GitHub owner/repo, the one-time
registration token and the admin SSH key are variables (secrets / tfvars), never committed. Remote
state lives in the `tfstate` container (`azurerm` backend); the state storage account is the one
chicken-and-egg — created once by a documented `az storage account create` (a bootstrap module would
be more code than the problem). Check = `terraform fmt -check` + `validate` + `plan`.

**8. What Terraform cannot do: the Kuskus grant.** `kuskushead` is an internal Microsoft cluster not
ARM-managed by this subscription, so `azurerm_kusto_database_principal_assignment` does not apply. The
MI's viewer grant is an out-of-band request to the Kuskus team:
`.add database Kuskus viewers ('aadapp=<mi-client-id>;<tenant>')`. Documented in the runner setup
notes; the pipeline fails closed (auth / getschema) until it lands.

## Components (Terraform)

| Resource | Purpose |
|---|---|
| Resource group | holds everything |
| User-assigned MI | Kusto auth (viewer on `Kuskus`, granted out-of-band); attached to the VM |
| Storage account (LRS) | `tfstate` (remote state) + `kuskus-state` (watermark blob) |
| VNet + subnet + NSG | egress-only network; NSG denies all inbound |
| Public IP (Standard) + NIC | guaranteed outbound egress for the VM |
| Linux VM (`Standard_B2s`) | the persistent runner; cloud-init installs the toolchain + registers once; MI attached |
| Role assignment | Storage Blob Data Contributor (MI → `kuskus-state`) |

## Layout

```
infra/
  terraform/     main.tf variables.tf providers.tf backend.tf outputs.tf runner-init.sh.tftpl
  README.md      # state bootstrap, Kuskus viewer-grant request, registration-token + apply steps
```

## Testability / verification

- `terraform fmt -check` + `terraform validate` are the offline runnable checks; `terraform plan`
  against the subscription is the integration check (needs Azure creds).
- The cloud-init template is verified offline by rendering it with the var map and `bash -n` on the
  result (asserts the substitutions produce valid shell); at boot it self-checks the toolchain via the
  runner agent + `az`/`gh`/`python3 -c 'import azure.kusto.data'`.
- End-to-end (documented, not in CI — needs the live grant): a manual `workflow_dispatch` of
  `kuskus-report.yml` → the Online runner picks up the job → the getschema guard + fetch +
  calibrate/mine run → the watermark advances in the blob → no query text appears in any log → the
  scrub step clears `scratch/`.

## Config

| Var / secret | Meaning |
|---|---|
| `subscription_id` | Terraform var (the target subscription) |
| `location` | `westeurope` (co-located with the cluster) |
| `github_owner` / `github_repo` | `microsoft` / `kql-guard` |
| `runner_registration_token` | one-time token (minted at apply; consumed at first boot) |
| `admin_ssh_public_key` | VM break-glass key (inbound SSH stays NSG-denied) |
| `vm_size` | runner VM size (default `Standard_B2s`) |
| `KUSKUS_CLUSTER` (VM `.env`) | `https://kuskushead.westeurope.kusto.windows.net` (flip to `…conf` later) |
| `KUSKUS_STATE_DIR` (job env) | local dir synced to/from the `kuskus-state` blob |

## Skipped (YAGNI — each with its trigger)

- **Scale-to-zero / KEDA** — needs a durable GitHub credential the org caps at 8 days; the persistent
  VM avoids it. Revisit if org policy adds a long-lived App/PAT for us.
- **Auto-deallocate scheduler** — always-on is simpler; add a start/stop runbook if idle cost matters.
- **NAT gateway** — one Standard public IP (egress) is cheaper for a single VM; add if fanning out.
- **Key Vault** — no durable secret to store now; add if one appears.
- **Private endpoint / IP allow-list** — public AAD-only cluster; add if it restricts by IP.
- **AKS / ARC** — a weekly job doesn't warrant a cluster.
- **Download the shipped release binary** — the original scanner-acquisition path; replaced by
  build-from-source (HEAD-matching rules + `--shapes` + a compile-capable validate gate).
- **Bootstrap TF module** — one documented `az` command is smaller than the module.
