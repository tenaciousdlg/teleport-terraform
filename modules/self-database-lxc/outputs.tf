output "ca_cert" {
  description = "PEM of the private CA that signed the engine's server certificate. Feed this to modules/dynamic-registration as ca_cert_chain so Teleport trusts the engine."
  value       = tls_self_signed_cert.ca_cert.cert_pem
}

output "container_ip" {
  description = "Static IPv4 of the container"
  value       = var.container_ip
}

output "vm_id" {
  description = "Proxmox container ID"
  value       = var.vm_id
}

output "token_name" {
  description = "Name of the bound_keypair provision token the agent joins with"
  value       = teleport_provision_token.db.metadata.name
}

output "db_uri" {
  description = "URI for dynamic registration. localhost, because the agent shares the container with the engine and the engine listens nowhere else."
  value       = "localhost:${local.port}"
}
