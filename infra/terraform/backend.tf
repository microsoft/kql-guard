# Remote state lives in the `tfstate` container created once by the documented
# `az` bootstrap (see README.md) — the one chicken-and-egg a bootstrap module
# would only make heavier. `storage_account_name` is a partial config: pass it at
# init, e.g.
#   terraform init -backend-config="storage_account_name=<state-account>"
# For offline schema checks (no Azure creds) use `terraform init -backend=false`.
terraform {
  backend "azurerm" {
    resource_group_name = "kuskus-runner-tfstate"
    container_name      = "tfstate"
    key                 = "kuskus-runner.tfstate"
  }
}
