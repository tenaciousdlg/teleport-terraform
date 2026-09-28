# modules/proxmox-teleport-host — a Teleport agent host on a Proxmox LXC.
#
# WHY A NEW MODULE. `self-database-lxc` fuses "make an LXC" to "install an
# engine", and every other data-plane module is AWS. The portable half of the
# data plane (ssh nodes, app hosts, Machine ID targets) needs the container and
# the agent without the database, so that half is factored out here.
#
# TWO DIFFERENCES FROM self-database-lxc, both deliberate:
#
#   1. `initial_public_key`, not `registration_secret`. The estate default is a
#      pre-registered public key, because a public key is not a secret and the
#      token is then fully described in the repo with nothing in terraform
#      state. self-database-lxc predates that and still generates a
#      random_password into state.
#   2. `terraform_data`, not `null_resource`. Chris, 2026-09-27: "lets not use
#      null_resource where possible."
#
# THE COST OF (1), STATED: a keypair must exist before the token can reference
# it, so a brand-new host is a TWO-PHASE bootstrap — create the container,
# generate the key on it, then apply the token. That is not new; `agents.tf`
# and `terraform-bot.tf` already work this way, and the alternative is a secret
# in state. See README.md for the exact sequence.

variable "name" {
  description = "Short host name. Becomes the LXC hostname, the Teleport node name and the token name."
  type        = string
}

variable "proxmox_node" {
  description = "Proxmox node to build on."
  type        = string
  default     = "hollowtree"
}

variable "vm_id" {
  description = "LXC vmid. MUST also be added to the vzdump backup job, or the container is not backed up and nothing warns you."
  type        = number
}

variable "ip_address" {
  description = "Static CIDR for the container, e.g. 192.168.1.60/24. Static because the Proxmox bridge hands out no DHCP for these and the router therefore has no name to register — see the DNS note in README."
  type        = string
}

variable "gateway" {
  description = "Default gateway."
  type        = string
  default     = "192.168.1.1"
}

variable "cores" {
  description = "vCPUs. These hosts are demo targets, not workloads; 1 is usually right."
  type        = number
  default     = 1
}

variable "memory_mb" {
  description = "Memory CAP in MB. An LXC cap is a limit, not a reservation, so a generous cap costs nothing until it is used. Measured 2026-09-27: six containers held 21.5 GB of caps and used 3.5 GB."
  type        = number
  default     = 512
}

variable "disk_gb" {
  description = "Root disk in GB."
  type        = number
  default     = 8
}

variable "proxy_address" {
  description = "Teleport proxy, host only (no port)."
  type        = string
}

variable "initial_public_key" {
  description = <<-EOT
    PUBLIC half of the bound keypair this host joins with, in SSH
    authorized_keys format. In the repo on purpose: a public key is not a
    secret, and pre-registering it is what removes the onboarding secret from
    the bootstrap path entirely.

    Generate it ON THE CONTAINER, never with the tls_private_key provider —
    this layer uses a local backend, so a generated private key would sit in
    plaintext state. Reprint an existing one by re-running the create command
    WITHOUT --overwrite.
  EOT
  type        = string
}

variable "teleport_roles" {
  description = "Token roles. Node for SSH, App for application access, and both when the config enables both services — a Node-only token makes an App registration fall back to the legacy join path and fail with a message that reads like a capability problem."
  type        = list(string)
  default     = ["Node"]
}

variable "labels" {
  description = "Teleport resource labels. The estate convention is env + team + role."
  type        = map(string)
}

variable "apps" {
  description = "Application Service entries, if any. Each needs name + uri; an empty list omits app_service entirely."
  type = list(object({
    name = string
    uri  = string
  }))
  default = []
}

variable "provision_script" {
  description = "Optional shell script run inside the container after Teleport is installed, for whatever this host actually serves. Runs via `pct push` then execute, never stdin to `pct exec`."
  type        = string
  default     = ""
}

variable "proxmox_ssh" {
  description = "user@host for the Proxmox node, used for pct."
  type        = string
  default     = "root@hollowtree"
}

variable "template_file_id" {
  description = "LXC template. Note the provider IGNORES this after import and reads it back empty, because the API does not report which template a container came from."
  type        = string
  # VERIFIED against `pveam list local`, not assumed. The first draft guessed
  # 13.0-1 and the real one is 13.6-1; a wrong template fails at create.
  default = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
}

variable "teleport_version" {
  description = "Teleport version to install. Pin it: an agent newer than the cluster is unsupported."
  type        = string
  default     = "18.11.0"
}

variable "datastore_id" {
  description = "ZFS pool for the container's root disk. `ember` is where guests live on hollowtree; `ash` is the backup pool and is NOT where a running container belongs."
  type        = string
  default     = "ember"
}

variable "mcp_apps" {
  description = <<-EOT
    stdio MCP servers to expose. These are app_service entries but take an
    `mcp` stanza instead of a `uri`: Teleport LAUNCHES the command on demand and
    proxies stdio, rather than proxying to a listening address.

    `run_as_host_user` is REQUIRED for stdio MCP servers — it is the account the
    command runs as, and Teleport will not start one without it.

    Access needs the `mcp-user` preset role, or a role allowing app_labels
    `teleport.internal/app-sub-kind: mcp` plus `mcp.tools`. A host serving these
    also needs BOTH `Node` and `App` token roles.
  EOT
  type = list(object({
    name             = string
    command          = string
    args             = list(string)
    run_as_host_user = string
  }))
  default = []
}
