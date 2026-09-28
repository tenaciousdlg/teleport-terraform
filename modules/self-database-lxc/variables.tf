variable "db_type" {
  description = "Database engine on LXC: postgres, mysql or mongodb. NOT cassandra."

  # MONGODB ADDED 2026-09-28. The old text said "only postgres and mysql", but
  # the REASON given was specifically about Cassandra being a JVM and the
  # largest single consumer on the hypervisor for the engine demoed least.
  # That reason does not extend to MongoDB, which is a modest C++ daemon, so it
  # was exclusion by wording rather than by argument. Cassandra remains out for
  # the reason actually stated.
  validation {
    condition     = contains(["postgres", "mysql", "mongodb"], var.db_type)
    error_message = "db_type must be postgres, mysql or mongodb. Cassandra is deliberately unsupported on LXC: it is a JVM and would be the largest single consumer on the hypervisor, for the engine demoed least."
  }
  type = string
}

variable "db_hostname" {
  description = "CN / SAN for the server certificate, e.g. postgres.dev.internal"
  type        = string
}

variable "env" {
  description = "env label, also the first half of the container hostname"
  type        = string
}

variable "team" {
  description = "team label"
  type        = string
}

variable "proxy_address" {
  description = "Teleport proxy, without a port (e.g. teleport.chrisdlg.com)"
  type        = string
}

variable "teleport_db_ca" {
  description = "Teleport's db-client CA, from https://<proxy>/webapi/auth/export?type=db-client. Appended to the server's ssl_ca_file so the engine trusts certs Teleport presents."
  type        = string
}

# ---- Proxmox placement -----------------------------------------------------

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
}

variable "proxmox_ssh" {
  description = "user@host for SSH to the Proxmox node. Provisioning runs `pct exec` over this hop, matching 1-cluster."
  type        = string
}

variable "vm_id" {
  description = "Container ID"
  type        = number
}

variable "container_ip" {
  description = "Static IPv4 for the container, without the mask"
  type        = string
}

variable "container_netmask" {
  description = "CIDR prefix length"
  type        = number
  default     = 24
}

variable "gateway" {
  description = "Default gateway"
  type        = string
}

variable "dns_servers" {
  description = <<-EOT
    Resolvers for the container. THE ROUTER MUST COME FIRST.

    Was ["1.1.1.1", "8.8.8.8"], which meant these containers could not resolve
    a single LAN name and anything pointing at the estate had to be written as
    a literal address. That is the failure the estate's no-hardcoded-IPs rule
    exists to prevent, arriving through the back door of a resolver default.

    A resolver is the one place an address is unavoidable: you cannot resolve
    a name to find the thing that resolves names. Everything downstream of it
    then gets to use names -- `siem.localdomain` in the rsyslog forwarder
    below, for one.
  EOT
  type        = list(string)
  default     = ["192.168.1.1", "1.1.1.1"]
}

variable "siem_target" {
  description = "Host:port for rsyslog forwarding to the SIEM. A NAME, resolved via the router. The A record is terraform-managed in homelab/unifi/dns.tf."
  type        = string
  default     = "siem.localdomain:1514"
}

variable "os_template_file_id" {
  description = "Proxmox volume ID of the Ubuntu 24.04 LXC template"
  type        = string
}

variable "datastore_id" {
  description = "Datastore for the container rootfs"
  type        = string
}

variable "disk_size" {
  description = "Root disk, GB"
  type        = number
  default     = 12
}

variable "memory" {
  description = "Memory cap in MB. A cap, not a reservation -- an idle Postgres sits near 100 MB."
  type        = number
  default     = 1024
}

variable "cpu_cores" {
  description = "CPU cores"
  type        = number
  default     = 2
}
