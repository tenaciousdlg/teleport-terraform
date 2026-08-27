variable "subscription_id" {
  description = "Azure subscription hosting the demo resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group to create (identity Reader is scoped to it)"
  type        = string
  default     = "rg-dlg-teleport-demo"
}

variable "proxy_address" {
  description = "Teleport proxy address (host, no port)"
  type        = string
}

variable "env" {
  description = "env label on the registered app"
  type        = string
  default     = "prod"
}

variable "team" {
  description = "team label on the registered app"
  type        = string
  default     = "platform"
}

variable "vm_size" {
  description = "Agent VM size"
  type        = string
  default     = "Standard_B2s"
}
