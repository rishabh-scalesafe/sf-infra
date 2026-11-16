# Renders cloud-init for k3s server / agent nodes. Cloud-agnostic: every cloud module uses this.

terraform {
  required_version = ">= 1.6.0"
}

variable "role" {
  type        = string
  description = "server or agent"
  validation {
    condition     = contains(["server", "agent"], var.role)
    error_message = "role must be server or agent."
  }
}

variable "k3s_version" {
  type        = string
  description = "Pinned k3s release, e.g. v1.36.5+k3s1"
}

variable "k3s_token" {
  type        = string
  sensitive   = true
  description = "Shared cluster join token"
}

variable "server_url" {
  type        = string
  default     = ""
  description = "https://<server-private-ip>:6443 (agents only)"
}

variable "tls_sans" {
  type        = list(string)
  default     = []
  description = "Extra API server cert SANs (public IP, DNS name)"
}

variable "cloud" {
  type = string
}

variable "cluster_name" {
  type = string
}

output "rendered" {
  sensitive = true
  value = templatefile("${path.module}/templates/k3s-node.yaml.tftpl", {
    role         = var.role
    k3s_version  = var.k3s_version
    k3s_token    = var.k3s_token
    server_url   = var.server_url
    tls_sans     = var.tls_sans
    cloud        = var.cloud
    cluster_name = var.cluster_name
  })
}
