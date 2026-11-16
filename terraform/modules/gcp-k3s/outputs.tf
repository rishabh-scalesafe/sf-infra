output "server_public_ip" {
  value = google_compute_address.server.address
}

output "server_private_ip" {
  value = google_compute_address.server_internal.address
}

output "agent_public_ips" {
  value = google_compute_instance.agent[*].network_interface[0].access_config[0].nat_ip
}

output "ingress_ips" {
  description = "Any node IP serves ingress (k3s ServiceLB). Point DNS here."
  value = concat(
    [google_compute_address.server.address],
    google_compute_instance.agent[*].network_interface[0].access_config[0].nat_ip
  )
}

output "ssh_user" {
  value = var.ssh_user
}
