terraform {
  required_version = ">= 1.6.0"

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

  backend "azurerm" {
    resource_group_name  = "rg-tfbackend-jordprojs"
    storage_account_name = "sttfbejordprojs8557"
    container_name       = "tfstate"
    key                  = "azure-website-uptime-monitor/dev.terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "random" {}

data "azurerm_client_config" "current" {}
