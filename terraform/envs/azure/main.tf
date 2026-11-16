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
  # Safest place for state: remote, encrypted, locked, NOT in git. See docs/STATE.md.
  # Until enabled, state is local and gitignored.
  # backend "azurerm" {
  #   resource_group_name  = "scalesafe-tfstate-rg"
  #   storage_account_name = "scalesafetfstate"
  #   container_name       = "tfstate"
  #   key                  = "k3s-azure.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

module "cluster" {
  source         = "../../modules/azure-k3s"
  cluster_name   = var.cluster_name
  location       = var.location
  admin_cidrs    = var.admin_cidrs
  web_cidrs      = var.web_cidrs
  ssh_public_key = file(pathexpand(var.ssh_public_key_path))
  k3s_version    = var.k3s_version
  k3s_token      = random_password.k3s_token.result
  extra_tls_sans = var.extra_tls_sans
  server_size    = var.server_size
  agent_size     = var.agent_size
  agent_count    = var.agent_count
}
