output "token_name" {
  description = "The bound_keypair token this host joins with."
  value       = teleport_provision_token.agent.metadata.name
}

output "node_name" {
  description = "Teleport node name, which is also the LXC hostname."
  value       = var.name
}

output "ip_address" {
  description = "The container's static address."
  value       = var.ip_address
}

output "read_public_key_command" {
  description = "Phase-1 helper: prints the public half to paste into initial_public_key."
  value       = "ssh ${var.proxmox_ssh} 'pct exec ${var.vm_id} -- cat /var/lib/teleport-bkp/static-key.pub'"
}
