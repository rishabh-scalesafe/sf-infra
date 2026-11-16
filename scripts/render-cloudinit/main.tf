# Helper root: renders the shared k3s cloud-init (same template Terraform uses) for
# script-driven deployments (e.g. scripts/azure-quicktest.sh using `az vm create`).
variable "role" { type = string }
variable "k3s_version" { type = string }
variable "k3s_token" {
  type      = string
  sensitive = true
}
variable "server_url" {
  type    = string
  default = ""
}
variable "tls_sans" {
  type    = list(string)
  default = []
}
variable "cloud" { type = string }
variable "cluster_name" { type = string }

module "init" {
  source       = "../../terraform/modules/k3s-cloudinit"
  role         = var.role
  k3s_version  = var.k3s_version
  k3s_token    = var.k3s_token
  server_url   = var.server_url
  tls_sans     = var.tls_sans
  cloud        = var.cloud
  cluster_name = var.cluster_name
}

output "rendered" {
  value     = module.init.rendered
  sensitive = true
}
