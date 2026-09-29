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

variable "require_mfa" {
  # Arms per-session MFA on THIS host by adding `teleport.dev/mfa: required`,
  # which is the only label the `mfa-required` role matches
  # (control-plane/proxmox/3-rbac/mfa.tf). `require_session_mfa` combines as a
  # logical OR across roles, so this adds a prompt for this host and changes
  # nothing about any other.
  #
  # DEFAULTS TO TRUE, DELIBERATELY. The obvious design was a `-var` flag at arm
  # time, which is a footgun: a later routine `terraform apply` without the
  # flag would silently disarm the demo and nothing would report it. State
  # belongs in the declaration, not in whoever last typed the command.
  #
  # Disarm by flipping this to false and applying. Note that either direction
  # rewrites /etc/teleport.yaml and restarts the agent, so the node drops out
  # of `tsh ls` for a few seconds. Do it before an audience is watching.
  #
  # KEEP AT LEAST ONE COMPARABLE HOST UNARMED. The demo is a side-by-side --
  # same user, same command, one host prompts. dev-httpbin is the control.
  description = "Add the teleport.dev/mfa=required label, arming per-session MFA for this host."
  type        = bool
  default     = true
}
