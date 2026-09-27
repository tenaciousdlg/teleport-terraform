terraform {
  required_providers {
    teleport = {
      source = "terraform.releases.teleport.dev/gravitational/teleport"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

resource "random_string" "bot_token" {
  length  = 32
  special = false
}

resource "teleport_provision_token" "bot" {
  depends_on = [teleport_bot.this]

  version = "v2"
  metadata = {
    name        = random_string.bot_token.result
    description = "Provision token for Machine ID bot ${var.bot_name}"
  }
  spec = {
    roles       = ["Bot"]
    bot_name    = var.bot_name
    join_method = "bound_keypair"
    bound_keypair = {
      onboarding = local.onboarding
      recovery = {
        mode  = var.bound_keypair_recovery_mode
        limit = var.bound_keypair_recovery_limit
      }
    }
  }
}

resource "teleport_role" "machine" {
  version = "v7"
  metadata = {
    name        = var.role_name
    description = "Role for Machine ID bot access"
  }
  spec = {
    allow = local.allow
  }
}

locals {
  onboarding = var.onboarding_initial_public_key != "" ? { initial_public_key = var.onboarding_initial_public_key } : {}
  allow = merge(
    length(var.allowed_logins) > 0 ? { logins = var.allowed_logins } : {},
    length(var.node_labels) > 0 ? { node_labels = var.node_labels } : {},
    length(var.app_labels) > 0 ? { app_labels = var.app_labels } : {},
    length(var.mcp_tools) > 0 ? { mcp = { tools = var.mcp_tools } } : {},

    # ADDED 2026-09-27. Both new consumers needed grants this module could not
    # express, and the honest options were to extend it or to hand-write a
    # bot, token and role beside it for the third time. Extending wins: the
    # bound_keypair and onboarding logic here is the part that is easy to get
    # subtly wrong.
    #
    # Backwards compatible by construction: each entry merges only when its
    # variable is non-empty, and every new variable defaults to empty, so the
    # four existing consumers (full-platform, dev-demo, machineid-ansible,
    # machine-id-mcp) produce an identical allow block.
    length(var.rules) > 0 ? { rules = var.rules } : {},
    length(var.workload_identity_labels) > 0 ? { workload_identity_labels = var.workload_identity_labels } : {},
    length(var.db_labels) > 0 ? { db_labels = var.db_labels } : {},
    length(var.db_names) > 0 ? { db_names = var.db_names } : {},
    length(var.db_users) > 0 ? { db_users = var.db_users } : {},
    length(var.kubernetes_labels) > 0 ? { kubernetes_labels = var.kubernetes_labels } : {},
  )
}

resource "teleport_bot" "this" {
  metadata = {
    name = var.bot_name
  }

  spec = {
    roles = [teleport_role.machine.id]
  }
}
