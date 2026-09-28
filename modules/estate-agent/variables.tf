variable "nodename" {
  description = "Teleport nodename, and the hostname the node appears as in `tsh ls`."
  type        = string
}

variable "proxy_address" {
  description = "Teleport proxy host, no scheme and no port. :443 is appended."
  type        = string
}

variable "token_name" {
  description = "Provision token to join with. Must exist on the cluster (3-rbac/agents.tf) and must name this host's public key as initial_public_key."
  type        = string
}

variable "static_key_path" {
  description = "Path on the HOST to the bound_keypair static private key. Generated once with `tbot keypair create --static`; this module never creates or reads it."
  type        = string
  default     = "/etc/teleport-static-key"
}

variable "labels" {
  description = "ssh_service labels. The estate convention is env + team + role; see ~/github/CLAUDE.md."
  type        = map(string)
}

variable "log_severity" {
  description = "Teleport log severity. Raise to DEBUG before touching RBAC when 'unknown user' survives a correct role -- host user creation only explains itself at DEBUG."
  type        = string
  default     = "INFO"
}

variable "apps" {
  description = <<-EOT
    Apps this agent proxies. Empty disables app_service entirely.

    Each entry: { name, uri, labels, rewrite_headers (optional), comment (optional) }.

    NOTE on `uri`: these are LOOPBACK addresses served by the agent's own host.
    That is exactly why they are declared per-agent here rather than as dynamic
    `teleport_app` resources with label selectors -- a selector that matches the
    wrong agent advertises an app pointing at a port with nothing behind it.
    modules/self-database-lxc carries the scar from that with databases.
  EOT
  type = list(object({
    name            = string
    uri             = string
    labels          = map(string)
    rewrite_headers = optional(list(string), [])
    comment         = optional(string, "")
  }))
  default = []
}

variable "delivery" {
  description = <<-EOT
    How to write the rendered config to the host and restart the agent.

    mode = "proxmox_lxc": ssh to the Proxmox node, then `pct push` + `pct exec`.
      Requires ssh_target (the NODE, e.g. root@hollowtree) and vm_id.
      `pct push`, never stdin to `pct exec` -- the same trap as
      `tctl -f /dev/stdin` against the distroless auth pod.

    mode = "ssh_stdin": ssh to a host and pipe a script to a root shell there.
      Requires ssh_target and remote_shell. This exists for lgm, where the
      agent runs in WSL and there is no Proxmox API: remote_shell is
      `wsl -d Ubuntu -u root -e bash`. Long command lines fail through
      cmd.exe, so the payload goes over stdin rather than on the argv.
  EOT
  type = object({
    mode         = string
    ssh_target   = string
    vm_id        = optional(number)
    remote_shell = optional(string, "bash")
  })

  validation {
    condition     = contains(["proxmox_lxc", "ssh_stdin"], var.delivery.mode)
    error_message = "delivery.mode must be \"proxmox_lxc\" or \"ssh_stdin\"."
  }

  validation {
    condition     = var.delivery.mode != "proxmox_lxc" || var.delivery.vm_id != null
    error_message = "delivery.vm_id is required when delivery.mode is \"proxmox_lxc\"."
  }
}

variable "restart_agent" {
  description = "Restart teleport after writing the config. False writes the file and leaves the running agent alone, which is the safe setting for a first apply you want to diff before cutting over."
  type        = bool
  default     = true
}
