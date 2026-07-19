variable "subscription_id" {
  type        = string
  description = "Target Azure subscription id (56361900-... for the Kuskus runner)."
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
  description = "GitHub org/user that owns the repo and the App installation."
  default     = "microsoft"
}

variable "github_repo" {
  type        = string
  description = "Repo the ephemeral runner registers against."
  default     = "kql-guard"
}

# --- GitHub App: no defaults (ids identify a specific App; key is a secret). ---
variable "github_app_id" {
  type        = string
  description = "GitHub App id (KEDA scaler queue poll + runner registration)."
}

variable "github_app_installation_id" {
  type        = string
  description = "GitHub App installation id on the repo (KEDA scaler)."
}

variable "github_app_private_key" {
  type        = string
  description = "GitHub App private key PEM. Sourced from a CI secret / tfvars; never committed."
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
