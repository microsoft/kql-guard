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
