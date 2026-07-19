data "azurerm_client_config" "current" {}

# Storage-account and ACR names are globally unique; a short random suffix avoids
# collisions without hand-picking names.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  storage_name = "${var.name_prefix}${random_string.suffix.result}"    # <= 24 chars
  acr_name     = "${var.name_prefix}${random_string.suffix.result}acr" # <= 50 chars
  repo_url     = "https://github.com/${var.github_owner}/${var.github_repo}"
  runner_label = "kuskus"
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.name_prefix}-rg"
  location = var.location
}

# --- Identity: user-assigned MI for Kusto (viewer, granted out-of-band, D8). ---
resource "azurerm_user_assigned_identity" "runner" {
  name                = "${var.name_prefix}-mi"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# --- Runner image registry. ---
resource "azurerm_container_registry" "acr" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false # MI (AcrPull) only
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
}

# --- State storage: tfstate (remote state) + kuskus-state (durable watermark). ---
resource "azurerm_storage_account" "state" {
  name                     = local.storage_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "tfstate" {
  name               = "tfstate"
  storage_account_id = azurerm_storage_account.state.id
}

resource "azurerm_storage_container" "kuskus_state" {
  name               = "kuskus-state"
  storage_account_id = azurerm_storage_account.state.id
}

# Least-privilege: blob access scoped to the kuskus-state container only.
resource "azurerm_role_assignment" "blob_contributor" {
  scope                = azurerm_storage_container.kuskus_state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
}

# --- Container Apps environment (Consumption, no VNet). Log Analytics gives the
#     unattended job debuggable logs (and lets us assert "no query text in logs"). ---
resource "azurerm_log_analytics_workspace" "logs" {
  name                = "${var.name_prefix}-logs"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "env" {
  name                       = "${var.name_prefix}-env"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
}

# --- The ephemeral runner as a scale-to-zero Container App Job. KEDA's
#     github-runner scaler starts one replica per queued `kuskus` job; the runner
#     registers --ephemeral, runs the one job, and exits. ---
resource "azurerm_container_app_job" "runner" {
  name                         = "${var.name_prefix}-job"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  container_app_environment_id = azurerm_container_app_environment.env.id

  replica_timeout_in_seconds = var.replica_timeout_seconds
  replica_retry_limit        = 0 # an ephemeral runner can't retry a consumed job

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runner.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.runner.id
  }

  secret {
    name  = "github-pat"
    value = var.github_pat
  }

  event_trigger_config {
    parallelism              = 1
    replica_completion_count = 1

    scale {
      max_executions              = 1
      min_executions              = 0
      polling_interval_in_seconds = 30

      rules {
        name             = "github-runner"
        custom_rule_type = "github-runner"

        metadata = {
          owner                     = var.github_owner
          runnerScope               = "repo"
          repos                     = var.github_repo
          labels                    = local.runner_label
          targetWorkflowQueueLength = "1"
        }

        authentication {
          secret_name       = "github-pat"
          trigger_parameter = "personalAccessToken"
        }
      }
    }
  }

  template {
    container {
      name   = "runner"
      image  = "${azurerm_container_registry.acr.login_server}/kuskus-runner:${var.runner_image_tag}"
      cpu    = var.runner_cpu
      memory = var.runner_memory

      # Self-hosted runner registration (myoung34/github-runner base uses the PAT
      # to auto-register an --ephemeral runner and deregister it when the job ends).
      env {
        name  = "RUNNER_SCOPE"
        value = "repo"
      }
      env {
        name  = "REPO_URL"
        value = local.repo_url
      }
      env {
        name  = "LABELS"
        value = local.runner_label
      }
      env {
        name  = "EPHEMERAL"
        value = "true"
      }
      env {
        name  = "DISABLE_AUTO_UPDATE"
        value = "true"
      }
      env {
        name        = "ACCESS_TOKEN"
        secret_name = "github-pat"
      }

      # Pipeline config: consumed by scripts/fetch_corpus.py and the workflow's
      # `az login --identity` + blob watermark sync.
      env {
        name  = "KUSKUS_CLUSTER"
        value = var.kuskus_cluster
      }
      env {
        name  = "KUSKUS_DATABASE"
        value = var.kuskus_database
      }
      env {
        name  = "KUSKUS_MI_CLIENT_ID"
        value = azurerm_user_assigned_identity.runner.client_id
      }
      env {
        name  = "KUSKUS_STATE_ACCOUNT"
        value = azurerm_storage_account.state.name
      }
      env {
        name  = "KUSKUS_STATE_CONTAINER"
        value = azurerm_storage_container.kuskus_state.name
      }
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull]
}
