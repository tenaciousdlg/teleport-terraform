variable "project_id" {
  description = "GCP project hosting the agent VM and demo service accounts"
  type        = string
}

variable "zone" {
  description = "GCE zone for the agent VM"
  type        = string
  default     = "us-central1-a"
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

variable "machine_type" {
  description = "GCE machine type for the agent VM"
  type        = string
  default     = "e2-small"
}
