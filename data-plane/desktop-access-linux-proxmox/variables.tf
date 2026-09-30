variable "proxy_address" {
  description = "Teleport proxy hostname, no port."
  type        = string
  default     = "teleport.heronwright.com"
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
