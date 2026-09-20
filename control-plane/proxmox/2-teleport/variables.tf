# 2-teleport/variables.tf
#
# Adapted from eks/2-teleport/variables.tf. Dropped the AWS-specific vars
# (region, domain_name, use_dns_validation, certificate_duration) — standalone
# mode has no Route53/ACME/DNS validation. Intended value: proxy_address =
# teleport.chrisdlg.com (see README).

variable "env" {
  description = "Environment label for the Teleport cluster (chart labels.env)"
  type        = string
  default     = "prod"
}

variable "team" {
  description = "Team label for the Teleport cluster (chart labels.team)"
  type        = string
  default     = "platform"
}

variable "proxy_address" {
  description = "Name of your Teleport cluster / public proxy address (e.g. teleport.chrisdlg.com)"
  type        = string
}

variable "user" {
  description = "Email for the Teleport creator label / admin"
  type        = string
}

variable "teleport_version" {
  description = "Teleport version to deploy (e.g. 18.11.0)"
  type        = string
}

variable "access_graph_enabled" {
  description = "Enable Access Graph integration. Off for the Proxmox replica (5-access-graph is out of scope); kept so the auth teleportConfig block mirrors eks."
  type        = bool
  default     = false
}

variable "authentication_type" {
  description = "Primary auth connector type. Phase 1 default 'local' (no SSO yet — a 'saml' type with no connector makes /webapi/ping return 'no saml connectors found' and breaks web login). Flip to 'saml' in Phase 2 once the Okta SAML connector lands in 3-rbac; presales runs 'saml'."
  type        = string
  default     = "local"
}

variable "authentication_connector_name" {
  description = "Which connector the web UI offers by default when authentication_type is an SSO type. Empty lets Teleport pick; set explicitly so behaviour does not change if a second connector is ever added."
  type        = string
  default     = ""
}

variable "second_factors" {
  description = "Allowed second factors. Phase 1 includes 'otp' so a local admin can bootstrap without a passkey; presales is webauthn-only, so tighten to [\"webauthn\"] in Phase 2."
  type        = list(string)
  default     = ["webauthn", "otp"]
}

variable "access_graph_audit_log_enabled" {
  # DELIBERATELY OFF, and not a gap. Streaming the audit log into Access Graph
  # requires the Identity Activity Center, and IAC has a hard AWS dependency:
  # two S3 buckets (long-term Parquet + transient results), an SQS queue with a
  # dead-letter queue, Athena as the query engine, Glue for the schema catalog,
  # and a customer-managed KMS key. The Helm values are AWS-shaped throughout
  # (region, workgroup, sqs_queue_url, s3://...).
  #
  # PostgreSQL is explicitly NOT sufficient -- it only holds the graph data.
  # R2 could stand in for S3, but nothing self-hosted substitutes for Athena
  # and Glue, so this cannot run on the Proxmox replica at all.
  #
  # Decision 2026-09-20 (Chris): keep this stage on Proxmox, leave IAC off.
  # Access Graph itself -- the graph, the explorer, path analysis -- is the
  # bulk of Identity Security and is fully working without it. Turning this on
  # later is this one variable plus the AWS side.
  description = "Stream the audit log into Access Graph. Requires the Identity Activity Center, which needs AWS S3+SQS+Athena+Glue+KMS and therefore cannot run on this Proxmox cluster. Off by design; with it true and IAC absent, auth error-loops."
  type        = bool
  default     = false
}
