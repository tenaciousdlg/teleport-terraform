# 3-rbac/variables.tf
# Adapted from eks/3-rbac/variables.tf — dropped the AWS `region` var.
#
# PHASE 1 = LOCAL AUTH. The SAML (Okta) connectors in roles.tf are carried over
# but gated OFF by default (okta_metadata_url defaults to "", enable_okta_preview
# defaults false). They still reference the presales Okta apps and must be
# rewired to teleport.chrisdlg.com + NEW Okta apps before the SSO phase. Leave
# okta_metadata_url empty to skip them; the roles/AMRs/access-lists/kube-rbac/
# demo-apps all apply fine without SSO.

variable "proxy_address" {
  description = "Name of your Teleport cluster (e.g. teleport.chrisdlg.com)"
  type        = string
}

variable "okta_metadata_url" {
  description = "Okta SAML metadata URL for the PRIMARY connector. Empty (default) = do NOT create the Okta SAML connector (Phase 1 local auth). Set to a NEW Okta app's metadata URL for the SSO phase."
  type        = string
  default     = ""
}

variable "okta_preview_metadata_url" {
  description = "Okta preview SAML metadata URL (optional)"
  type        = string
  default     = ""
}

variable "enable_okta_preview" {
  description = "Whether to enable the Okta preview SAML connector"
  type        = bool
  default     = false
}

variable "teleport_namespace" {
  description = "Namespace where Teleport is installed"
  type        = string
  default     = "teleport-cluster"
}

variable "dev_team" {
  description = "Team label for dev environment resources"
  type        = string
  default     = "dev"
}

variable "prod_team" {
  description = "Team label for prod environment resources"
  type        = string
  default     = "platform"
}

variable "autoupdate_mode" {
  description = "Agent auto-update mode: 'enabled' for automatic rolling updates, 'disabled' to manage manually"
  type        = string
  default     = "enabled"
}

variable "autoupdate_target_version" {
  description = "Target Teleport version for agent + client-tools managed updates. Must not exceed the cluster version (upgrade 2-teleport first). Empty = no autoupdate_version resource; agents stay put."
  type        = string
  default     = ""
}

variable "autoupdate_start_version" {
  description = "Version agents update from; defaults to the target version when empty"
  type        = string
  default     = ""
}

variable "jit_admin_usernames" {
  # Who may have an `editor` access request auto-approved. Defaults to just the
  # access-list owner, which was right while auth was local and the only admin
  # was the local `dlg`. With Okta as the default login provider the usernames
  # are email addresses, and a condition matching the bare owner name silently
  # stops matching anyone -- the request is still created, it just waits
  # forever for a human reviewer.
  description = "Teleport usernames whose `editor` access requests auto-approve. Empty falls back to [access_list_owner]. Set via TF_VAR_jit_admin_usernames; kept out of the repo like access_list_owner."
  type        = list(string)
  default     = []
}

variable "access_list_owner" {
  description = "Teleport username that owns the access lists (runs membership reviews). Kept out of the repo — set via TF_VAR_access_list_owner."
  type        = string
}
