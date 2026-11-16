output "server_public_ip" {
  value = aws_eip.server.public_ip
}

output "server_private_ip" {
  value = aws_instance.server.private_ip
}

output "agent_public_ips" {
  value = aws_instance.agent[*].public_ip
}

output "ingress_ips" {
  description = "Any node IP serves ingress (k3s ServiceLB). Point DNS here."
  value       = concat([aws_eip.server.public_ip], aws_instance.agent[*].public_ip)
}

output "ssh_user" {
  value = "ubuntu"
}
