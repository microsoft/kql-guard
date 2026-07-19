## 1. Terraform skeleton + state backend

- [ ] 1.1 Create `infra/terraform/{providers,variables,backend,main,outputs}.tf`: `azurerm` + `azapi` providers; `subscription_id`, `location` (default `westeurope`), `github_owner`, `github_repo`, and GitHub App id/installation-id/private-key variables — **no defaults for ids or secrets**. `terraform fmt` + `terraform init` + `terraform validate` pass.
- [ ] 1.2 Document and run the one-time state bootstrap in `infra/README.md`: `az group create` (state RG) + `az storage account create` + `az storage container create --name tfstate`; point `backend.tf` at it and `terraform init` (migrate to remote state). ponytail: one `az` command, not a bootstrap module.

## 2. Core resources

- [ ] 2.1 Resource group; user-assigned MI; ACR (Basic); storage account with `tfstate` + `kuskus-state` containers.
- [ ] 2.2 Role assignments: MI → `AcrPull` on the ACR; MI → `Storage Blob Data Contributor` on the `kuskus-state` container.
- [ ] 2.3 `terraform validate` + `terraform plan` clean.

## 3. Runner image

- [ ] 3.1 `infra/runner-image/Dockerfile`: base = GitHub Actions runner; install `az`, `python3` + `pip install azure-kusto-data` (pinned), `gh`, `jq`. Entry registers an `--ephemeral` runner with label `kuskus` and runs one job.
- [ ] 3.2 Build + push via `az acr build` (documented). Check: `docker run <img> python3 -c 'import azure.kusto.data'`, `az version`, `gh --version` all succeed. ponytail: no .NET SDK — the scanner is downloaded per run.

## 4. Container Apps environment + Job + KEDA scaler

- [ ] 4.1 `azurerm_container_app_environment` (Consumption, no VNet).
- [ ] 4.2 `azurerm_container_app_job`: image from ACR, MI attached, `KUSKUS_*` env, GitHub App private key as a secret; `event_trigger_config` with a `github-runner` custom scale rule (owner/repo, `runnerScope: repo`, labels `kuskus`, GitHub App auth), parallelism 1, replica timeout sized to a full run.
- [ ] 4.3 `terraform plan` shows the job + scale rule; document GitHub App creation/installation in `infra/README.md`.

## 5. GitHub App + secrets

- [ ] 5.1 Document GitHub App creation in `infra/README.md` (permissions `administration:write`, `actions:read`; installed on the repo); store app id / installation id / private key as Container App secrets (Terraform vars sourced from CI secrets, never committed).
- [ ] 5.2 Confirm PR-open uses the workflow `GITHUB_TOKEN` (the workflow already declares `pull-requests: write`) — no extra secret.

## 6. Workflow restructure (`kuskus-report.yml`)

- [ ] 6.1 Merge `calibrate` + `mine` into one `run` job (`runs-on: [self-hosted, kuskus]`): checkout → `gh release download kql-guard-linux-x64` → watermark-in → `scripts/fetch-corpus.sh` (real fetch) → `scripts/run-calibration.sh` → `scripts/run-mining.sh` → watermark-out. Keep the `apply`/`corpus_path` dispatch inputs.
- [ ] 6.2 Watermark blob sync: before fetch, `az storage blob download -c kuskus-state -n watermark.txt -f "$KUSKUS_STATE_DIR/watermark.txt"` (tolerate not-found → fetch bootstraps); after a successful fetch step (`if: success()`), `az storage blob upload --overwrite ...` the same file.
- [ ] 6.3 Update the deferred-integrations header note: the fetch is live; the AI suggester remains deferred (mock covers mining).
- [ ] 6.4 Cross-ref: the fetch **unstub semantics** live in `kuskus-corpus-fetch` §6; this change owns the **job-merge + blob sync + release-download**. Implement `kuskus-report.yml` once, coherently, covering both.

## 7. Docs + validation

- [ ] 7.1 `infra/README.md`: state bootstrap, GitHub App setup, the `.add database Kuskus viewers ('aadapp=<mi-client-id>;<tenant>')` grant request to the Kuskus team, `terraform apply`, `az acr build`, and the first-dispatch smoke procedure.
- [ ] 7.2 `terraform fmt -check` + `terraform validate` green; `terraform plan` reviewed against the target subscription.
- [ ] 7.3 `openspec validate kuskus-runner-infra --strict` passes.
- [ ] 7.4 Manual smoke (documented, not in CI): dispatch → KEDA starts the job → ephemeral runner → getschema guard + fetch + calibrate/mine → watermark advances in the blob → no query text in any log.
