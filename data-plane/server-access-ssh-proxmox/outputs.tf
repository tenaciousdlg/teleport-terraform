output "read_public_key_command" {
  description = "Phase-1 helper: prints the public half to paste into initial_public_key."
  value       = module.ssh_node.read_public_key_command
}

output "node_name" { value = module.ssh_node.node_name }
output "ip_address" { value = module.ssh_node.ip_address }
