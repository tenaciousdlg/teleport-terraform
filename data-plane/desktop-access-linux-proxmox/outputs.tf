output "read_public_key_command" {
  description = "Phase-1 helper: prints the public half to paste into initial_public_key."
  value       = module.linux_desktop.read_public_key_command
}

output "node_name" { value = module.linux_desktop.node_name }
