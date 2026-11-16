# Points Cloudflare DNS at ANY cluster's ingress IPs (Azure, AWS, GCP, bare metal...).
# Cloud-agnostic by design: it only needs IPs, so switching clouds = changing origin_ips.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID (dashboard > domain > Overview > API)."
}

variable "zone_name" {
  type        = string
  description = "e.g. scalesafe.co.in"
}

variable "origin_ips" {
  type        = list(string)
  description = "Ingress IPs of the target cluster (terraform output ingress_ips)."
}

variable "hostnames" {
  type        = list(string)
  description = "Sub-domains to point at the cluster."
  default     = ["app", "argocd", "tekton", "hooks"]
}

variable "proxied" {
  type        = bool
  default     = true
  description = "Orange-cloud (Cloudflare proxy/WAF/DDoS). Keep true and lock origin to Cloudflare IPs."
}

locals {
  records = { for pair in setproduct(var.hostnames, var.origin_ips) : "${pair[0]}-${pair[1]}" => {
    name = pair[0]
    ip   = pair[1]
  } }
}

resource "cloudflare_dns_record" "this" {
  for_each = local.records
  zone_id  = var.zone_id
  name     = "${each.value.name}.${var.zone_name}"
  type     = "A"
  content  = each.value.ip
  proxied  = var.proxied
  ttl      = 1 # automatic
  comment  = "managed by terraform (scalesafe infra)"
}

output "fqdns" {
  value = distinct([for r in cloudflare_dns_record.this : r.name])
}
