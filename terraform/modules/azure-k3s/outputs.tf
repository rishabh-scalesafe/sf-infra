output "server_public_ip" {
  value = azurerm_public_ip.server.ip_address
}

output "server_private_ip" {
  value = azurerm_network_interface.server.private_ip_address
}

output "agent_public_ips" {
  value = azurerm_public_ip.agent[*].ip_address
}

output "ingress_ips" {
  description = "Any node IP serves ingress (k3s ServiceLB). Point DNS here."
  value       = concat([azurerm_public_ip.server.ip_address], azurerm_public_ip.agent[*].ip_address)
}

output "ssh_user" {
  value = var.admin_username
}

output "resource_group" {
  value = azurerm_resource_group.this.name
}
