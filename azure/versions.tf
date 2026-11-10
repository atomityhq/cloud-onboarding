terraform {
  required_version = ">= 1.5.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    # azurerm cannot create FOCUS exports (it only knows ActualCost,
    # AmortizedCost and Usage), so the export goes through azapi.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# Pinning tenant_id on every provider means a wrong `az login` context fails
# immediately instead of creating resources in the wrong tenant.
provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azurerm" {
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id # null = Azure CLI default or ARM_SUBSCRIPTION_ID
  features {}

  # The module registers the one provider it needs itself (see main.tf) and
  # must never register or unregister anything else in the customer's tenant.
  resource_provider_registrations = "none"
}

provider "azapi" {
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id
}