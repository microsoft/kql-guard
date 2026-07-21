data "azurerm_client_config" "current" {}

# Storage-account names are globally unique; a short random suffix avoids
# collisions without hand-picking names.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  storage_name = "${var.name_prefix}${random_string.suffix.result}" # <= 24 chars
  repo_url     = "https://github.com/${var.github_owner}/${var.github_repo}"
  runner_label = "kuskus"
  # Pinned to the runner-only dependency in scripts/manifest.schema.md.
  azure_kusto_data_version = "6.0.4"
  # .NET SDK channel the runner installs to build kql-guard from source (net10).
  dotnet_channel = "10.0"
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

# --- State storage: tfstate (remote state) + kuskus-state (durable watermark). ---
resource "azurerm_storage_account" "state" {
  name                     = local.storage_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  # Subscription policy denies anonymous blob access; the MI reads the watermark
  # via AAD (--auth-mode login), so no blob is ever public. ponytail: required by policy.
  allow_nested_items_to_be_public = false
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

# --- Azure OpenAI: the new-rule drafter's model endpoint. Approach A transmits
# ONLY the already-public masked shape signature (see scripts/suggest-rule.md),
# so a standard public endpoint with default retention is acceptable — no
# confidential data crosses the runner->model boundary.
# ponytail: the confidential real-text upgrade (feeding real query Text) needs a
# private endpoint + Zero-Data-Retention (Modified Abuse Monitoring). Provision
# those here only when the adapter's stdin becomes real Text, not before.
resource "azurerm_cognitive_account" "aoai" {
  name                  = "${var.name_prefix}aoai${random_string.suffix.result}"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "${var.name_prefix}aoai${random_string.suffix.result}" # required for Entra ID (MI) data-plane auth
  local_auth_enabled    = false                                                  # MI-only; no account keys in the data path
}

resource "azurerm_cognitive_deployment" "drafter" {
  name                 = var.aoai_model
  cognitive_account_id = azurerm_cognitive_account.aoai.id

  model {
    format  = "OpenAI"
    name    = var.aoai_model
    version = var.aoai_model_version
  }

  sku {
    name     = "Standard"
    capacity = var.aoai_deployment_capacity
  }
}

# Least-privilege: inference only (no author/manage) for the runner MI.
resource "azurerm_role_assignment" "aoai_user" {
  scope                = azurerm_cognitive_account.aoai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
}

# --- Networking: egress-only. The runner polls GitHub outbound; nothing needs
#     inbound, so the NSG denies all inbound and a Standard public IP gives
#     guaranteed egress (cheaper than a NAT gateway for a single VM). ---
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.name_prefix}-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.42.0.0/24"]
}

resource "azurerm_subnet" "runner" {
  name                 = "runner"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.0.0/27"]
}

resource "azurerm_network_security_group" "runner" {
  name                = "${var.name_prefix}-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  # Deny all inbound (outbound default-allow kept). Break-glass is via Serial
  # Console / Bastion, neither of which needs an inbound rule here.
  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "runner" {
  subnet_id                 = azurerm_subnet.runner.id
  network_security_group_id = azurerm_network_security_group.runner.id
}

resource "azurerm_public_ip" "runner" {
  name                = "${var.name_prefix}-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "runner" {
  name                = "${var.name_prefix}-nic"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.runner.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.runner.id
  }
}

# --- The persistent classic self-hosted runner. cloud-init installs the
#     toolchain, writes the KUSKUS_* job env, and registers the runner ONCE with
#     the one-time token (then it holds its own credential — no durable secret).
#     Registers while the operator has repo admin; survives later admin lapses. ---
resource "azurerm_linux_virtual_machine" "runner" {
  name                = "${var.name_prefix}-vm"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.runner.id]

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runner.id]
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/runner-init.sh.tftpl", {
    repo_url                 = local.repo_url
    registration_token       = var.runner_registration_token
    labels                   = local.runner_label
    runner_name              = "${var.name_prefix}-vm"
    azure_kusto_data_version = local.azure_kusto_data_version
    dotnet_channel           = local.dotnet_channel
    kuskus_cluster           = var.kuskus_cluster
    kuskus_database          = var.kuskus_database
    mi_client_id             = azurerm_user_assigned_identity.runner.client_id
    aoai_endpoint            = azurerm_cognitive_account.aoai.endpoint
    aoai_deployment          = azurerm_cognitive_deployment.drafter.name
    aoai_api_version         = var.aoai_api_version
    state_account            = azurerm_storage_account.state.name
    state_container          = azurerm_storage_container.kuskus_state.name
  }))
}
