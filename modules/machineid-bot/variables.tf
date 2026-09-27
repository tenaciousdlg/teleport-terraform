variable "bot_name" {
  description = "Name of the Machine ID bot"
  type        = string
}

variable "role_name" {
  description = "Name of the Teleport role to create"
  type        = string
}

variable "allowed_logins" {
  description = "System users that this role is allowed to log in as"
  type        = list(string)
  default     = []
}

variable "node_labels" {
  description = "Node labels the role should have access to"
  type        = map(list(string))
  default     = {}
}

variable "app_labels" {
  description = "App labels the role should have access to"
  type        = map(list(string))
  default     = {}
}

variable "mcp_tools" {
  description = "MCP tool allow list"
  type        = list(string)
  default     = []
}

variable "onboarding_initial_public_key" {
  description = "Optional SSH public key for preregistered bound keypair onboarding"
  type        = string
  default     = ""
}

variable "bound_keypair_recovery_limit" {
  description = "Maximum number of bound keypair recovery rejoins allowed"
  type        = number
  default     = 10
}

variable "bound_keypair_recovery_mode" {
  description = "Bound keypair recovery mode: standard, relaxed, or insecure"
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "relaxed", "insecure"], var.bound_keypair_recovery_mode)
    error_message = "bound_keypair_recovery_mode must be one of: standard, relaxed, insecure."
  }
}

variable "rules" {
  # Arbitrary resource rules, for bots that read the API rather than reach
  # infrastructure. A usage exporter needs read/list on node, app_server,
  # db_server, bot and so on; a SPIFFE issuer needs it on workload_identity.
  # Neither is expressible with the label variables above.
  description = "Resource rules granted to the bot's role."
  type = list(object({
    resources = list(string)
    verbs     = list(string)
  }))
  default = []
}

variable "workload_identity_labels" {
  # The label whitelist that scopes which workload_identity resources a bot
  # may issue. This is the control that makes a SPIFFE issuer bot safe, so it
  # belongs in the module rather than being bolted on beside it.
  description = "Workload identity labels the role may issue."
  type        = map(list(string))
  default     = {}
}

variable "db_labels" {
  description = "Database labels the role should have access to."
  type        = map(list(string))
  default     = {}
}

variable "db_names" {
  description = "Logical database names the role may connect to."
  type        = list(string)
  default     = []
}

variable "db_users" {
  description = "Database users the role may connect as."
  type        = list(string)
  default     = []
}

variable "kubernetes_labels" {
  description = "Kubernetes cluster labels the role should have access to."
  type        = map(list(string))
  default     = {}
}
