variable "proxy_address" {
  description = "Teleport proxy without a port, e.g. teleport.chrisdlg.com"
  type        = string
}

variable "env" {
  description = "env label. Also names the container and the registered database."
  type        = string
  default     = "dev"
}

variable "team" {
  description = "team label"
  type        = string
  default     = "platform"
}

# ---- Proxmox ---------------------------------------------------------------

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://192.168.1.10:8006/ . Null uses PROXMOX_VE_ENDPOINT."
  type        = string
  default     = null
}

variable "proxmox_api_token" {
  description = "Proxmox API token, 'user@realm!tokenid=uuid'. NEVER hardcode -- set TF_VAR_proxmox_api_token or PROXMOX_VE_API_TOKEN."
  type        = string
  default     = null
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification against the Proxmox API (self-signed cert on the node)."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node to create the container on"
  type        = string
  default     = "hollowtree"
}

variable "proxmox_ssh_host" {
  description = "SSH-reachable address of the Proxmox node (the host that runs `pct`)"
  type        = string
  default     = "192.168.1.10"
}

variable "proxmox_ssh_user" {
  description = "SSH user on the node -- must be able to run `pct` (i.e. root)"
  type        = string
  default     = "root"
}

variable "vm_id" {
  description = "Container ID. 105 continues the estate's sequence after 104 (siem)."
  type        = number
  default     = 105
}

variable "container_ip" {
  description = "Static IPv4, continuing from .51 (siem)."
  type        = string
  default     = "192.168.1.52"
}

variable "gateway" {
  description = "Default gateway"
  type        = string
  default     = "192.168.1.1"
}

variable "os_template_file_id" {
  description = "Proxmox volume ID of the Ubuntu 24.04 LXC template"
  type        = string
  default     = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "datastore_id" {
  description = "Datastore for the container rootfs"
  type        = string
  default     = "ember"
}
