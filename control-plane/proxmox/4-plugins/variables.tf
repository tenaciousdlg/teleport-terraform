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

# REMOVED 2026-09-21: variable "event_handler_registration_secret".
#
# The bot now pre-registers a PUBLIC key (local.event_handler_public_key in
# event-handler.tf), so there is no onboarding secret and nothing for this
# variable to carry. Removing it also removes a trap: it had `default = ""`
# and gated the token with `count = ... != "" ? 1 : 0`, so forgetting to
# export it did not fail the plan -- it planned to DESTROY the live token,
# the same shape as the SAML connector in 3-rbac.
#
# The `registration_secret` field in secret/demo/teleport-event-handler is now
# dead. That entry still holds fluentbit_server_key_passphrase, which is a
# real secret and stays.
