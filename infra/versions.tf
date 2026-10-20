terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13.0"
    }
  }
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  environment                     = "public"
  resource_provider_registrations = "none"

  features {
    cognitive_account {
      purge_soft_delete_on_destroy = false
    }
  }
}

provider "azapi" {
  subscription_id            = var.subscription_id
  environment                = "public"
  skip_provider_registration = true
}
