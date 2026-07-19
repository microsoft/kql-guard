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
  description = "Prefix for all resource names. Lowercase alphanumeric (used in globally-unique storage/ACR names)."
  default     = "kuskusrunner"
}

variable "github_owner" {
  type        = string
  description = "GitHub org/user that owns the repo the runner registers against."
  default     = "microsoft"
}

variable "github_repo" {
  type        = string
  description = "Repo the ephemeral runner registers against."
  default     = "kql-guard"
}

# --- GitHub auth: a PAT with `repo` scope (repo-level self-hosted runners).
# Verified viable on microsoft/kql-guard: repo admin + org policy allow repo
# runners (a registration-token mint succeeded), so no GitHub App install /
# org approval is needed. The PAT registers the ephemeral runner and drives the
# KEDA queue poll. Owner must keep repo admin for per-run registration to work;
# if admin is non-persistent, use a persistent-VM classic runner (registers once).
variable "github_pat" {
  type        = string
  description = "GitHub PAT (classic: `repo` scope; or fine-grained: repo Administration RW + Actions RO + Metadata RO on kql-guard). Runner registration + KEDA scaler. Sourced from a secret; never committed."
  sensitive   = true
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

variable "runner_image_tag" {
  type        = string
  description = "Tag of the runner image in the ACR (built out-of-band via `az acr build`)."
  default     = "latest"
}

variable "runner_cpu" {
  type        = number
  description = "vCPU per replica. Must pair with runner_memory per Container Apps Consumption combos."
  default     = 1.0
}

variable "runner_memory" {
  type        = string
  description = "Memory per replica (e.g. 2Gi pairs with 1.0 vCPU)."
  default     = "2Gi"
}

variable "replica_timeout_seconds" {
  type        = number
  description = "Hard cap on one pipeline run before the replica is killed."
  default     = 3600
}
