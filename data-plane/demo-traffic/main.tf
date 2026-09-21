##################################################################################
# DEMO TRAFFIC GENERATOR
##################################################################################
#
# A Machine ID bot whose only job is to exercise resources so the audit log and
# the SIEM have something real in them. Without it the dashboards are honest but
# empty: a cluster nobody logs into emits almost nothing, and detection rules
# written against an empty baseline are guesses.
#
# Machine ID rather than a human session because this has to run unattended:
# SSO plus the MFA-on-admin-actions gate means a human login cannot be scripted,
# and bots are exempt. It also means the traffic is attributable -- every event
# carries bot-demo-traffic, so generated load is trivially separable from real
# use in any query.
#
# PRE-FLIGHT:  source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv teleport
#
# Read-mostly on purpose. This thing runs on a timer; it should not be able to
# do anything it cannot undo.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "~> 18.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "teleport" {}

resource "teleport_role" "demo_traffic" {
  version = "v7"
  metadata = {
    name        = "demo-traffic"
    description = "Read-mostly access for the unattended traffic generator"
  }
  spec = {
    allow = {
      # Databases: both roles, so reader-vs-writer authorisation differences
      # show up in the audit log rather than only successful queries.
      db_labels = {
        "env" = ["dev"]
      }
      db_users = ["reader", "writer"]
      db_names = ["postgres"]

      # Apps: grafana and ollama both live behind Teleport already.
      app_labels = {
        "env" = ["home", "dev"]
      }

      # Kubernetes: a scoped read-only group, never system:masters.
      kubernetes_labels = {
        "*" = ["*"]
      }
      kubernetes_groups    = ["teleport-prod-viewers"]
      kubernetes_resources = [{ kind = "*", namespace = "*", name = "*", verbs = ["get", "list"] }]
    }
    options = {
      # Short, because this identity exists only for the length of a run.
      max_session_ttl = "1h0m0s"
    }
  }
}

resource "teleport_bot" "demo_traffic" {
  name  = "demo-traffic"
  roles = [teleport_role.demo_traffic.metadata.name]
}

resource "random_password" "registration_secret" {
  length  = 48
  special = false
}

resource "teleport_provision_token" "demo_traffic" {
  version = "v2"
  metadata = {
    name = "demo-traffic"
  }
  spec = {
    roles       = ["Bot"]
    bot_name    = teleport_bot.demo_traffic.name
    join_method = "bound_keypair"
    bound_keypair = {
      onboarding = {
        registration_secret = random_password.registration_secret.result
      }
      recovery = {
        # `mode` deliberately unset -- see modules/self-database-lxc. Setting it
        # to "standard" breaks agent joins; leaving it empty is what the working
        # agents on this cluster use.
        limit = 20
      }
    }
  }
}

output "registration_secret" {
  description = "Write to the path named in the tbot config. Sensitive; never commit."
  value       = random_password.registration_secret.result
  sensitive   = true
}
