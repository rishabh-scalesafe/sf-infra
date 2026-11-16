# Point your Cloudflare domain at whichever cluster you want:
#   terraform apply -var-file=terraform.tfvars
# with origin_ips taken from `terraform output ingress_ips` in envs/azure | envs/aws | envs/gcp.
# Switching clouds = change origin_ips and apply again.
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Reads CLOUDFLARE_API_TOKEN from the environment. Token scope: Zone > DNS > Edit, single zone.
provider "cloudflare" {}

module "dns" {
  source     = "../../modules/cloudflare-dns"
  zone_id    = var.zone_id
  zone_name  = var.zone_name
  origin_ips = var.origin_ips
  hostnames  = var.hostnames
  proxied    = var.proxied
}

variable "zone_id" {
  type = string
}

variable "zone_name" {
  type    = string
  default = "scalesafe.co.in"
}

variable "origin_ips" {
  type = list(string)
}

variable "hostnames" {
  type    = list(string)
  default = ["app", "argocd", "tekton", "hooks"]
}

variable "proxied" {
  type    = bool
  default = true
}

output "fqdns" {
  value = module.dns.fqdns
}
