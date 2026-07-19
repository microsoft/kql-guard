## 1. Terraform skeleton + state backend

- [x] 1.1 Create `infra/terraform/{providers,variables,backend,main,outputs}.tf`: `azurerm` provider; `subscription_id`, `location` (default `westeurope`), `github_owner`, `github_repo`, `runner_registration_token` (sensitive), `admin_ssh_public_key`, `vm_size` — **no defaults for ids or secrets**. `terraform fmt` + `terraform init` + `terraform validate` pass.
- [x] 1.2 Document and run the one-time state bootstrap in `infra/README.md`: `az group create` (state RG) + `az storage account create` + `az storage container create --name tfstate`; point `backend.tf` at it and `terraform init` (migrate to remote state). ponytail: one `az` command, not a bootstrap module.

## 2. Core resources

- [x] 2.1 Resource group; user-assigned MI; storage account with `tfstate` + `kuskus-state` containers.
- [x] 2.2 Role assignment: MI → `Storage Blob Data Contributor` on the `kuskus-state` container.
- [ ] 2.3 `terraform validate` + `terraform plan` clean.

## 3. Runner VM provisioning (cloud-init)

- [x] 3.1 `infra/terraform/runner-init.sh.tftpl` (VM cloud-init): install the GitHub Actions runner agent + `az`, `python3` + `azure-kusto-data` (pinned), `gh`, `jq`; write the `KUSKUS_*` job `.env`; register the runner (label `kuskus`) once with the one-time token as a systemd service. ponytail: no image/ACR — install on the VM.
- [x] 3.2 Offline check: render the template with the var map + `bash -n` the result (valid shell, all `${}` placeholders resolve). ponytail: no .NET SDK — the scanner is downloaded per run.

## 4. Networking + runner VM

- [x] 4.1 Egress-only network: VNet + subnet + NSG (deny all inbound) + Standard public IP + NIC.
- [x] 4.2 `azurerm_linux_virtual_machine` (`Standard_B2s`, Ubuntu): MI attached, `admin_ssh_key`, `custom_data` = the cloud-init template rendered with the `KUSKUS_*` + registration inputs.
- [ ] 4.3 `terraform plan` shows the VM + networking; document the registration-token mint in `infra/README.md`.

## 5. Runner registration + secrets

- [x] 5.1 Document the one-time registration-token mint in `infra/README.md` (`gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token`); passed as `TF_VAR_runner_registration_token`, consumed at first boot — no durable GitHub secret on the VM.
- [x] 5.2 Confirm PR-open uses the workflow `GITHUB_TOKEN` (the workflow already declares `pull-requests: write`) — no extra secret.

## 6. Workflow restructure (`kuskus-report.yml`)

- [x] 6.1 Merge `calibrate` + `mine` into one `run` job (`runs-on: [self-hosted, kuskus]`): checkout → `gh release download kql-guard-linux-x64` → watermark-in → `scripts/fetch-corpus.sh` (real fetch) → `scripts/run-calibration.sh` → `scripts/run-mining.sh` → watermark-out. Keep the `apply`/`corpus_path` dispatch inputs.
- [x] 6.2 Watermark blob sync: before fetch, `az storage blob download -c kuskus-state -n watermark.txt -f "$KUSKUS_STATE_DIR/watermark.txt"` (tolerate not-found → fetch bootstraps); after a successful fetch step (`if: success()`), `az storage blob upload --overwrite ...` the same file.
- [x] 6.3 Update the deferred-integrations header note: the fetch is live; the AI suggester remains deferred (mock covers mining).
- [x] 6.4 Cross-ref: the fetch **unstub semantics** live in `kuskus-corpus-fetch` §6; this change owns the **job-merge + blob sync + release-download**. Implement `kuskus-report.yml` once, coherently, covering both.
- [x] 6.5 Trust boundary on a reused workspace: add a final `if: always()` step that `rm -rf scratch "$KUSKUS_STATE_DIR"` so query text never persists past a run (the persistent VM does not discard its filesystem). Never touch a user-supplied `corpus_path`.

## 7. Docs + validation

- [x] 7.1 `infra/README.md`: state bootstrap, one-time registration-token mint, the `.add database Kuskus viewers ('aadapp=<mi-client-id>;<tenant>')` grant request to the Kuskus team, `terraform apply` (token + SSH key), and the first-dispatch smoke procedure.
- [ ] 7.2 `terraform fmt -check` + `terraform validate` green; `terraform plan` reviewed against the target subscription.
- [x] 7.3 `openspec validate kuskus-runner-infra --strict` passes.
- [ ] 7.4 Manual smoke (documented, not in CI): dispatch → the Online runner picks up the job → getschema guard + fetch + calibrate/mine → watermark advances in the blob → no query text in any log → scrub clears `scratch/`.
