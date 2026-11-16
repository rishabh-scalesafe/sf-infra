terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # backend "s3" {
  #   bucket       = "scalesafe-tfstate"
  #   key          = "k3s-aws.tfstate"
  #   region       = "ap-south-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "scalesafe", managed_by = "terraform" }
  }
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

module "cluster" {
  source               = "../../modules/aws-k3s"
  cluster_name         = var.cluster_name
  admin_cidrs          = var.admin_cidrs
  web_cidrs            = var.web_cidrs
  ssh_public_key       = file(pathexpand(var.ssh_public_key_path))
  k3s_version          = var.k3s_version
  k3s_token            = random_password.k3s_token.result
  extra_tls_sans       = var.extra_tls_sans
  server_instance_type = var.server_instance_type
  agent_instance_type  = var.agent_instance_type
  agent_count          = var.agent_count
}
