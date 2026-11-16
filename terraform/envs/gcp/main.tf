terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # backend "gcs" {
  #   bucket = "scalesafe-tfstate"
  #   prefix = "k3s-gcp"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

module "cluster" {
  source              = "../../modules/gcp-k3s"
  cluster_name        = var.cluster_name
  region              = var.region
  zone                = var.zone
  admin_cidrs         = var.admin_cidrs
  web_cidrs           = var.web_cidrs
  ssh_public_key      = file(pathexpand(var.ssh_public_key_path))
  k3s_version         = var.k3s_version
  k3s_token           = random_password.k3s_token.result
  extra_tls_sans      = var.extra_tls_sans
  server_machine_type = var.server_machine_type
  agent_machine_type  = var.agent_machine_type
  agent_count         = var.agent_count
}
