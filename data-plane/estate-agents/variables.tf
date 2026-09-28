variable "proxy_address" {
  description = <<-EOT
    Teleport proxy host, no scheme and no port.

    THIS IS THE CUTOVER SWITCH. Changing it here rewrites and restarts both
    agents on the next apply. It does NOT clear their data_dirs, which still
    hold certs from the old cluster's CA — see the README.
  EOT
  type        = string
  default     = "teleport.chrisdlg.com"
}

variable "proxmox_ssh" {
  description = "SSH target for the Proxmox NODE that runs `pct` (not the container). Name, not an address."
  type        = string
  default     = "root@hollowtree"
}

variable "lgm_ssh_target" {
  description = "SSH target for the Windows host running the WSL distro. A NAME the router resolves, never a literal address."
  type        = string
  default     = "lgm-win"
}

variable "restart_agents" {
  description = <<-EOT
    Restart teleport after writing the config.

    SET FALSE FOR A CLUSTER CUTOVER. Changing `proxy_address` and restarting in
    one step leaves both agents DOWN: the new config points at the new cluster
    while /var/lib/teleport still holds certs issued by the OLD cluster's CA,
    and no config change evicts them. The agent restarts, fails to join, and
    stays failed until the data_dir is wiped.

    With this false the new config lands on disk and the running agent keeps
    serving the OLD cluster untouched, so the cutover becomes a single
    deliberate stop/wipe/start per host rather than a window of downtime that
    starts the moment terraform applies.
  EOT
  type        = bool
  default     = true
}
