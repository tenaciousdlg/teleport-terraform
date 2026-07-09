variable "proxy_address" {
  description = "Teleport proxy hostname (no scheme, no port)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "env" {
  description = "Environment label"
  type        = string
  default     = "prod"
}

variable "team" {
  description = "Team label"
  type        = string
  default     = "platform"
}

variable "teleport_namespace" {
  description = "Kubernetes namespace where Teleport is installed"
  type        = string
  default     = "teleport-cluster"
}

variable "db_password" {
  description = "Master password for the Access Graph PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "teleport_host_ca" {
  description = "PEM-encoded Teleport host CA certificate. Retrieve with: curl 'https://<proxy>/webapi/auth/export?type=tls-host'"
  type        = string
}

variable "access_graph_chart_version" {
  description = "Helm chart version for teleport-access-graph (empty = latest)"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Identity Activity Center (IAC) — AWS analytics pipeline for the Dashboard.
# Names are presales-scoped; S3 buckets get an account-id suffix in iac.tf
# for global uniqueness.
# ---------------------------------------------------------------------------
variable "iac_sqs_queue_name" {
  description = "SQS queue for Identity Activity Center event ingestion"
  type        = string
  default     = "presales-teleport-iac-events"
}

variable "iac_sqs_dlq_name" {
  description = "SQS dead-letter queue for unprocessable IAC events"
  type        = string
  default     = "presales-teleport-iac-dlq"
}

variable "max_receive_count" {
  description = "Times a message can be received before moving to the DLQ"
  type        = number
  default     = 20
}

variable "iac_kms_key_alias" {
  description = "Alias for the IAC KMS key"
  type        = string
  default     = "presales-teleport-iac"
}

variable "iac_long_term_bucket_name" {
  description = "Long-term S3 bucket for IAC event storage (account id appended)"
  type        = string
  default     = "presales-teleport-iac-events"
}

variable "iac_transient_bucket_name" {
  description = "Transient S3 bucket for Athena results/large files (account id appended)"
  type        = string
  default     = "presales-teleport-iac-transient"
}

variable "iac_database_name" {
  description = "Glue database name (lowercase/underscores)"
  type        = string
  default     = "presales_teleport_iac"
}

variable "iac_table_name" {
  description = "Glue table name"
  type        = string
  default     = "identity_activity"
}

variable "iac_workgroup" {
  description = "Athena workgroup for IAC queries"
  type        = string
  default     = "presales-teleport-iac"
}

variable "iac_workgroup_max_scanned_bytes_per_query" {
  description = "Per-query scanned-bytes cap (cost control)"
  type        = number
  default     = 21474836480 # 20GB
}
