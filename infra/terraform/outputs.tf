output "resource_group" {
  description = "Resource group holding the runner infra."
  value       = azurerm_resource_group.rg.name
}

output "vm_name" {
  description = "The persistent runner VM (Serial Console / Bastion for break-glass)."
  value       = azurerm_linux_virtual_machine.runner.name
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

# Copy-paste this on a REGIONAL Kuskus cluster (e.g. kuskusweu.westeurope) — NOT kuskushead, which
# holds only the best_effort macro-expand function (QueryCompletion data lives on the ~20 regional
# entity_group members). One regional grant suffices; see infra/README.md §4. Terraform cannot run it
# (the cluster is not ARM-managed by this subscription, D8).
output "kuskus_viewer_grant_command" {
  description = "Out-of-band grant — run on a REGIONAL Kuskus cluster (e.g. kuskusweu.westeurope), not kuskushead. See infra/README §4."
  value       = ".add database ${var.kuskus_database} viewers ('aadapp=${azurerm_user_assigned_identity.runner.client_id};${data.azurerm_client_config.current.tenant_id}')"
}

output "aoai_endpoint" {
  description = "Azure OpenAI endpoint the new-rule drafter calls (KUSKUS_AOAI_ENDPOINT)."
  value       = azurerm_cognitive_account.aoai.endpoint
}

output "aoai_deployment" {
  description = "Azure OpenAI deployment name (KUSKUS_AOAI_DEPLOYMENT)."
  value       = azurerm_cognitive_deployment.drafter.name
}
