variable "subscription_id" {
  type        = string
  description = "Target Azure subscription id (92288740-... = Kusto_PM_Experiments, verified Owner + westeurope)."
}

variable "location" {
  type        = string
  description = "Azure region; co-located with the Kuskus cluster."
  default     = "westeurope"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for all resource names. Lowercase alphanumeric (used in the globally-unique storage-account name)."
  default     = "kuskusrunner"
}

variable "github_owner" {
  type        = string
  description = "GitHub org/user that owns the repo the runner registers against."
  default     = "microsoft"
}

variable "github_repo" {
  type        = string
  description = "Repo the persistent runner registers against."
  default     = "kql-guard"
}

# --- GitHub runner registration: a ONE-TIME registration token (valid ~1h,
# single-use), minted at apply with:
#   gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token
# The VM consumes it once at first boot to register the persistent runner, which
# then holds its own credential. NOT a durable secret (unlike a PAT/App), so it
# sidesteps the org's 8-day classic-PAT SSO cap. Re-mint only if the VM is recreated.
variable "runner_registration_token" {
  type        = string
  description = "One-time GitHub Actions runner registration token (mint at apply; consumed on first boot)."
  sensitive   = true
}

variable "admin_ssh_public_key" {
  type        = string
  description = "SSH public key for the VM admin (break-glass only; inbound SSH stays NSG-denied). e.g. file(\"~/.ssh/id_rsa.pub\")."
}

variable "admin_username" {
  type        = string
  description = "VM admin username (break-glass)."
  default     = "runneradmin"
}

variable "vm_size" {
  type        = string
  description = "Runner VM size. B2s (2 vCPU / 4 GiB) fits the AOT scanner + fetch; always-on ~30 USD/mo."
  default     = "Standard_B2s"
}

variable "kuskus_cluster" {
  type        = string
  description = "ADX cluster URL the fetch queries. Flip to the confidential cluster later."
  default     = "https://kuskushead.westeurope.kusto.windows.net"
}

variable "kuskus_database" {
  type        = string
  description = "ADX database holding QueryCompletion."
  default     = "Kuskus"
}

variable "aoai_model" {
  type        = string
  description = "Azure OpenAI model for the new-rule drafter. Approach A sends only public-safe masked signatures. Must be a GA chat model in the account's region (az cognitiveservices account list-models). The GPT-5 family is reasoning-only, so the adapter sends no temperature."
  default     = "gpt-5-mini"
}

# ponytail: real-world knob — models retire. gpt-4o/gpt-4.1 all went Deprecating in
# westeurope by 2026-07; the GPT-5 family is the GA chat option. Confirm before pinning:
#   az cognitiveservices account list-models -n <acct> -g <rg> -o table
variable "aoai_model_version" {
  type        = string
  description = "Pinned model version for the deployment (avoids silent model drift). Must be a non-deprecated version deployable on aoai_deployment_sku in the account's region."
  default     = "2025-08-07"
}

variable "aoai_deployment_capacity" {
  type        = number
  description = "Deployment capacity (thousands of TPM). The drafter fires at most once per mining run, so the floor is plenty."
  default     = 10
}

# ponytail: real-world knob — docs list a SKU as "available" but the region's live
# capacity can still 400. Regional "Standard" for gpt-4o is often unavailable in
# westeurope; DataZoneStandard keeps data in the EU zone (right for the confidential
# upgrade) and is more available. Flip to "GlobalStandard" if this is also constrained.
variable "aoai_deployment_sku" {
  type        = string
  description = "AOAI deployment SKU. DataZoneStandard = EU-resident processing; GlobalStandard = broadest availability (routes globally); Standard = single-region (often capacity-constrained for gpt-4o)."
  default     = "DataZoneStandard"
}

variable "aoai_api_version" {
  type        = string
  description = "AOAI data-plane api-version the adapter calls. Must support json_schema structured outputs AND the deployed model family (GPT-5 needs a 2025+ version). The adapter fails closed, so an unsupported value just skips the draft — bump it if a live run logs a call failure."
  default     = "2025-04-01-preview"
}
