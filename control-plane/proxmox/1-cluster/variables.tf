# 1-cluster/variables.tf
#
# This layer stands up a single-node k3s cluster inside a PRIVILEGED LXC
# container on the `hollowtree` Proxmox node (reworked from the earlier VM
# version — Chris prefers containers over VMs on Proxmox where feasible, and
# k3s runs fine in a privileged CT on this host; cgroup v2 confirmed).

##################################################################################
# Proxmox connection (API)
##################################################################################

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://192.168.1.10:8006/ . Leave null to use PROXMOX_VE_ENDPOINT."
  type        = string
  default     = null
}

variable "proxmox_api_token" {
  description = "Proxmox API token in the form 'user@realm!tokenid=uuid'. Leave null to use PROXMOX_VE_API_TOKEN. NEVER hardcode — set via TF_VAR_proxmox_api_token or the env var."
  type        = string
  default     = null
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification against the Proxmox API (self-signed cert on the homelab node). Leave null to use PROXMOX_VE_INSECURE."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node name to create the container on"
  type        = string
  default     = "hollowtree"
}

##################################################################################
# Proxmox node SSH (for the raw lxc.conf tweaks + k3s install via `pct exec`)
#
# The bpg provider does NOT expose the raw `lxc.*` container keys k3s needs
# (apparmor unconfined, cgroup2 device access, rw proc/sys, no dropped caps), so
# those are applied by a null_resource that SSHes the node and appends them to
# /etc/pve/lxc/<vmid>.conf. The k3s install itself then runs inside the CT via
# `pct exec` over that same SSH — so we never need to SSH the container directly.
# Uses the caller's ssh-agent, same as the provider's ssh{ agent = true }.
##################################################################################

variable "proxmox_ssh_host" {
  description = "SSH-reachable address of the Proxmox node itself (the host that runs `pct`), used by the lxc.conf + k3s-install local-execs. Usually the same box as the API endpoint."
  type        = string
  default     = "192.168.1.10"
}

variable "proxmox_ssh_user" {
  description = "SSH user on the Proxmox node — must be able to run `pct` and write /etc/pve/lxc/<vmid>.conf (i.e. root)"
  type        = string
  default     = "root"
}

##################################################################################
# Container specs (privileged LXC)
##################################################################################

variable "container_hostname" {
  description = "Hostname of the k3s LXC container"
  type        = string
  default     = "teleport-k3s"
}

variable "container_vm_id" {
  description = "Explicit Proxmox VMID for the container. Leave null to let Proxmox auto-assign the next free ID."
  type        = number
  default     = null
}

variable "os_template_file_id" {
  description = "Proxmox volume ID of the Ubuntu 24.04 LXC template (already present on the node — no cloud-init template needed for a CT)."
  type        = string
  default     = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "container_cpu_cores" {
  description = "vCPU cores"
  type        = number
  default     = 4
}

variable "container_memory_mb" {
  description = "RAM in MiB"
  type        = number
  default     = 8192
}

variable "container_swap_mb" {
  description = "Swap in MiB"
  type        = number
  default     = 512
}

variable "container_disk_gb" {
  description = "Rootfs size in GiB"
  type        = number
  default     = 40
}

variable "datastore_id" {
  description = "Proxmox datastore for the container rootfs"
  type        = string
  default     = "ember"
}

variable "network_bridge" {
  description = "Proxmox bridge to attach the container NIC to"
  type        = string
  default     = "vmbr0"
}

##################################################################################
# Networking (static IP so the address is deterministic for the cloudflared
# origin and the k3s --tls-san — no guest-agent / DHCP discovery race).
##################################################################################

variable "container_ip" {
  description = "Static IPv4 for the container. Default 192.168.1.50 is FRESH (free) — CT102 stays on 192.168.1.45 as the live cloudflared tunnel origin until this replica is validated, then the origin is repointed .45 -> .50 in cloudflare-infra and CT102 is retired. See README."
  type        = string
  default     = "192.168.1.50"
}

variable "container_netmask" {
  description = "IPv4 CIDR prefix length for the container address"
  type        = number
  default     = 24
}

variable "gateway" {
  description = "Default gateway for the container"
  type        = string
  default     = "192.168.1.1"
}

variable "dns_servers" {
  description = "DNS servers for the container"
  type        = list(string)
  default     = ["192.168.1.1", "1.1.1.1"]
}

##################################################################################
# Container root access (OPTIONAL)
#
# Primary access is via the Proxmox node (`pct exec`/`pct console`), so neither
# of these is required for a working apply. Set an SSH key if you want to reach
# the CT directly for debugging.
##################################################################################

variable "container_ssh_public_key" {
  description = "OPTIONAL SSH public key to authorize for root on the container (for direct `ssh root@<container_ip>` debugging). Empty = no direct SSH; use `pct exec`/`pct console` from the node instead."
  type        = string
  default     = ""
}

variable "container_root_password" {
  description = "OPTIONAL root password for the container (enables `pct console` login). Empty/null = no password set."
  type        = string
  default     = null
  sensitive   = true
}

variable "k3s_version" {
  description = "Pin a specific k3s version (INSTALL_K3S_VERSION), e.g. v1.31.5+k3s1. Empty = latest stable channel."
  type        = string
  default     = ""
}
