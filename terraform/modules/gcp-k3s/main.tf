# k3s cluster on plain GCP Compute Engine VMs (1 server + N agents).

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

locals {
  name   = var.cluster_name
  labels = merge({ project = "scalesafe", cluster = var.cluster_name, managed_by = "terraform" }, var.labels)
  tag    = "${var.cluster_name}-node"
}

resource "google_compute_network" "this" {
  name                    = "${local.name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${local.name}-nodes"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.this.id
}

resource "google_compute_firewall" "internal" {
  name          = "${local.name}-internal"
  network       = google_compute_network.this.name
  source_ranges = [var.subnet_cidr]
  target_tags   = [local.tag]
  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

resource "google_compute_firewall" "admin" {
  name          = "${local.name}-admin"
  network       = google_compute_network.this.name
  source_ranges = var.admin_cidrs
  target_tags   = [local.tag]
  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }
}

resource "google_compute_firewall" "web" {
  name          = "${local.name}-web"
  network       = google_compute_network.this.name
  source_ranges = var.web_cidrs
  target_tags   = [local.tag]
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "google_service_account" "nodes" {
  account_id   = "${local.name}-nodes"
  display_name = "ScaleSafe k3s nodes (no roles granted)"
}

# ---------------------------------------------------------------- server
resource "google_compute_address" "server" {
  name   = "${local.name}-server"
  region = var.region
}

resource "google_compute_address" "server_internal" {
  name         = "${local.name}-server-internal"
  region       = var.region
  subnetwork   = google_compute_subnetwork.nodes.id
  address_type = "INTERNAL"
  address      = cidrhost(var.subnet_cidr, 10)
}

module "server_init" {
  source       = "../k3s-cloudinit"
  role         = "server"
  k3s_version  = var.k3s_version
  k3s_token    = var.k3s_token
  tls_sans     = concat([google_compute_address.server.address], var.extra_tls_sans)
  cloud        = "gcp"
  cluster_name = var.cluster_name
}

resource "google_compute_instance" "server" {
  name         = "${local.name}-server-0"
  machine_type = var.server_machine_type
  zone         = var.zone
  tags         = [local.tag]
  labels       = merge(local.labels, { role = "server" })

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nodes.id
    network_ip = google_compute_address.server_internal.address
    access_config {
      nat_ip = google_compute_address.server.address
    }
  }

  metadata = {
    user-data              = module.server_init.rendered
    ssh-keys               = "${var.ssh_user}:${var.ssh_public_key}"
    block-project-ssh-keys = "true"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  service_account {
    email  = google_service_account.nodes.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    ignore_changes = [metadata["user-data"], boot_disk[0].initialize_params[0].image]
  }
}

# ---------------------------------------------------------------- agents
module "agent_init" {
  source       = "../k3s-cloudinit"
  role         = "agent"
  k3s_version  = var.k3s_version
  k3s_token    = var.k3s_token
  server_url   = "https://${google_compute_address.server_internal.address}:6443"
  cloud        = "gcp"
  cluster_name = var.cluster_name
}

resource "google_compute_instance" "agent" {
  count        = var.agent_count
  name         = "${local.name}-agent-${count.index}"
  machine_type = var.agent_machine_type
  zone         = var.zone
  tags         = [local.tag]
  labels       = merge(local.labels, { role = "agent" })

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nodes.id
    access_config {}
  }

  metadata = {
    user-data              = module.agent_init.rendered
    ssh-keys               = "${var.ssh_user}:${var.ssh_public_key}"
    block-project-ssh-keys = "true"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  service_account {
    email  = google_service_account.nodes.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    ignore_changes = [metadata["user-data"], boot_disk[0].initialize_params[0].image]
  }

  depends_on = [google_compute_instance.server]
}
