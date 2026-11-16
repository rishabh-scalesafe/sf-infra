variable "subscription_id" {
  type = string
}

variable "cluster_name" {
  type    = string
  default = "scalesafe-prod"
}

variable "location" {
  type    = string
  default = "centralindia"
}

variable "admin_cidrs" {
  type = list(string)
}

variable "web_cidrs" {
  type = list(string)
}

variable "ssh_public_key_path" {
  type = string
}

variable "k3s_version" {
  type    = string
  default = "v1.36.5+k3s1"
}

variable "extra_tls_sans" {
  type    = list(string)
  default = []
}

variable "server_size" {
  type    = string
  default = "Standard_B2as_v2"
}

variable "agent_size" {
  type    = string
  default = "Standard_B2as_v2"
}

variable "agent_count" {
  type    = number
  default = 1
}

output "server_public_ip" {
  value = module.cluster.server_public_ip
}

output "ingress_ips" {
  value = module.cluster.ingress_ips
}

output "ssh_user" {
  value = module.cluster.ssh_user
}
