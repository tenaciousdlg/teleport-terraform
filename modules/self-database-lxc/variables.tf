variable "db_type" {
  description = "Database engine. Only postgres and mysql are supported on LXC -- Cassandra is a JVM and would be the largest single consumer on the hypervisor, for the engine demoed least."
  type        = string
  validation {
    condition     = contains(["postgres", "mysql"], var.db_type)
    error_message = "db_type must be postgres or mysql. Use modules/self-database (EC2) for cassandra or mongodb."
  }
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
  description = "Resolvers for the container"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
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
