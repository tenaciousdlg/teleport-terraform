variable "proxy_address" {
  description = "Teleport proxy hostname, no port."
  type        = string
  default     = "teleport.heronwright.com"
}

variable "initial_public_key" {
  description = <<-EOT
    PUBLIC half of the static bound keypair, generated ON the container during
    phase 1. Not a secret, so it lives in this repo.

    Phase 1 leaves it empty; read the generated key with the module's
    `read_public_key_command` output and set it here for phase 2.
  EOT
  type        = string
  default     = ""
}

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint. From ~/github/homelab/proxmox/vault-env.sh."
  type        = string
  default     = null
}

variable "proxmox_api_token" {
  description = "Proxmox API token. From Vault via vault-env.sh — never hardcode."
  type        = string
  sensitive   = true
  default     = null
}

variable "proxmox_insecure" {
  description = "Proxmox uses a self-signed cert."
  type        = bool
  default     = true
}
