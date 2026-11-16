variable "cluster_name" {
  type    = string
  default = "scalesafe"
}

variable "location" {
  type    = string
  default = "centralindia"
}

variable "vnet_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.10.1.0/24"
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach SSH (22) and the Kubernetes API (6443). Never 0.0.0.0/0."
  validation {
    condition     = length(var.admin_cidrs) > 0 && !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "admin_cidrs must be set and must not contain 0.0.0.0/0."
  }
}

variable "web_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach 80/443. Use Cloudflare IP ranges when fronted by Cloudflare."
}

variable "admin_username" {
  type    = string
  default = "scalesafe"
}

variable "ssh_public_key" {
  type = string
}

variable "k3s_version" {
  type = string
}

variable "k3s_token" {
  type      = string
  sensitive = true
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

variable "disk_size_gb" {
  type    = number
  default = 64
}

variable "encryption_at_host" {
  type        = bool
  default     = false
  description = "Requires the EncryptionAtHost feature registered on the subscription."
}

variable "tags" {
  type    = map(string)
  default = {}
}
