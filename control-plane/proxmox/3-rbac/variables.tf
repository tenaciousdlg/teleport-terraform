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

variable "chrisdlg_saml_entity_descriptor" {
  # The Okta app's SAML metadata XML, inline. NOT entity_descriptor_url: that
  # endpoint returns 403 without an API token, verified from both this Mac and
  # from inside the cluster, so Teleport cannot fetch it itself.
  #
  # Source it from the okta repo rather than pasting:
  #   terraform -chdir=~/github/okta output -raw chrisdlg_teleport_saml_metadata
  #
  # Kept out of this repo like the other IdP values -- set
  # TF_VAR_chrisdlg_saml_entity_descriptor locally. Empty creates no connector.
  description = "SAML metadata XML for the teleport.chrisdlg.com Okta app. Empty disables the connector."
  type        = string
  default     = ""
}

variable "estate_agents" {
  # Personal machines running a Teleport agent from OUTSIDE k3s, by name. Each
  # gets a bound_keypair join token `agent-<name>` in agents.tf. Not secret --
  # recording which machines are enrolled is the point of keeping them here.
  # Each name needs a matching entry in local.agent_public_keys in agents.tf.
  description = "Estate machines outside k3s that join with their own bound_keypair token."
  type        = list(string)
  default     = []
}

# REMOVED 2026-09-21: variable "agent_registration_secrets".
#
# The estate agents now pre-register a PUBLIC key
# (local.agent_public_keys in agents.tf), so there is no onboarding secret to
# supply and nothing for this variable to carry. Deleting it is most of the
# point of that migration:
#
#   - the Vault entry secret/demo/teleport-agent-join is no longer read by
#     anything. Keep it only until both agents are confirmed re-joined on
#     static keys, as rollback; then delete it.
#   - it had `default = {}` yet was indexed directly, so a plan without it
#     died with `Invalid index ... each.key is "lgm"` -- an error that reads
#     like a for_each bug and was an unexported variable. That is gone.
#   - this layer no longer needs ANY sensitive variable to plan. The only
#     remaining external one is chrisdlg_saml_entity_descriptor, which is
#     public IdP metadata rather than a secret.

variable "terraform_bot_public_key" {
  # PUBLIC half of the bound keypair the Terraform provider's bot joins with, in
  # SSH authorized_keys format. Not a secret -- it lives in the repo on purpose,
  # because pre-registering it is what removes the registration secret from the
  # bootstrap path entirely.
  #
  # Workstation-specific. Regenerate with:
  #   tbot keypair create --proxy-server=teleport.chrisdlg.com:443 \
  #     --storage=file:///Users/dlg/.tbot/teleport-terraform
  description = "Public key pre-registered on the terraform-local bound_keypair token."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPpqp8Sg8zH7jca/mZoOvyeTQh/C6VR72c1/KCdlkamK"
}
