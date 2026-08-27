variable "proxy_address" {
  description = "Teleport proxy address (host, no port)"
  type        = string
}

variable "azure_subscription_id" {
  description = "Azure subscription for the demo resource group"
  type        = string
}

variable "gcp_project_id" {
  description = "GCP project for the agent VM and service accounts"
  type        = string
}

variable "enable_azure" {
  description = "Deploy the Azure CLI access agent"
  type        = bool
  default     = true
}

variable "enable_gcp" {
  description = "Deploy the GCP CLI access agent"
  type        = bool
  default     = true
}

variable "env" {
  description = "env label on registered apps (prod = revealed by JIT elevation)"
  type        = string
  default     = "prod"
}

variable "team" {
  description = "team label on registered apps"
  type        = string
  default     = "platform"
}
