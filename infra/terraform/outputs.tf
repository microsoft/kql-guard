output "resource_group" {
  description = "Resource group holding the runner infra."
  value       = azurerm_resource_group.rg.name
}

output "acr_login_server" {
  description = "ACR login server; `az acr build` target for the runner image."
  value       = azurerm_container_registry.acr.login_server
}

output "acr_name" {
  description = "ACR name for `az acr build --registry <name>`."
  value       = azurerm_container_registry.acr.name
}

output "mi_client_id" {
  description = "User-assigned MI client id (KUSKUS_MI_CLIENT_ID; used in the Kusto grant)."
  value       = azurerm_user_assigned_identity.runner.client_id
}

output "mi_principal_id" {
  description = "User-assigned MI principal (object) id."
  value       = azurerm_user_assigned_identity.runner.principal_id
}

output "storage_account" {
  description = "State storage account (tfstate + kuskus-state containers)."
  value       = azurerm_storage_account.state.name
}

output "container_app_job" {
  description = "Container App Job name."
  value       = azurerm_container_app_job.runner.name
}

# Copy-paste this on the Kuskus cluster to grant the MI viewer on the database
# (Terraform cannot: the cluster is not ARM-managed by this subscription, D8).
output "kuskus_viewer_grant_command" {
  description = "Out-of-band grant to request from the Kuskus team."
  value       = ".add database ${var.kuskus_database} viewers ('aadapp=${azurerm_user_assigned_identity.runner.client_id};${data.azurerm_client_config.current.tenant_id}')"
}
