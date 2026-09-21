variable "proxy_address" {
  description = "Teleport proxy hostname (no scheme, no port)"
  type        = string
}

variable "teleport_namespace" {
  description = "Namespace where Teleport is installed"
  type        = string
  default     = "teleport-cluster"
}

variable "plugin_namespace" {
  description = "Kubernetes namespace to deploy the Slack plugin into"
  type        = string
  default     = "teleport-plugins"
}

variable "slack_bot_token" {
  description = "Slack Bot User OAuth Token (starts with xoxb-)"
  type        = string
  sensitive   = true
}

variable "slack_channel_id" {
  description = "Slack channel ID for access request notifications (right-click channel → Copy Link, or channel About tab)"
  type        = string
}

variable "plugin_chart_version" {
  description = "Helm chart version for teleport-plugin-slack (empty = latest)"
  type        = string
  default     = ""
}

variable "event_handler_registration_secret" {
  # bound_keypair onboarding secret for the event handler's bot. Lives in
  # Vault at secret/demo/teleport-event-handler; set it with
  #   TF_VAR_event_handler_registration_secret=$(vault kv get -field=registration_secret secret/demo/teleport-event-handler)
  # Empty creates no token, which is correct for a cluster with no SIEM.
  description = "bound_keypair registration secret for the event handler bot. Kept out of the repo."
  type        = string
  sensitive   = true
  default     = ""
}
