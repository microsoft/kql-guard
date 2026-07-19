terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# azapi is intentionally NOT used: the VM, networking, storage, MI and role
# assignments are all native in azurerm 4.x, so a second provider would be
# dead config.
provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
