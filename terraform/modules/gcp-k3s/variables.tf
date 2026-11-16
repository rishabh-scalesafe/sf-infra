variable "cluster_name" {
  type    = string
  default = "scalesafe"
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "zone" {
  type    = string
  default = "asia-south1-a"
}

variable "subnet_cidr" {
  type    = string
  default = "10.30.1.0/24"
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

variable "ssh_user" {
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

variable "server_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "agent_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "agent_count" {
  type    = number
  default = 1
}

variable "disk_size_gb" {
  type    = number
  default = 64
}

variable "labels" {
  type    = map(string)
  default = {}
}
