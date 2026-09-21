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
    description = "IAC: read-mostly access for the unattended traffic generator"
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

      # Kubernetes: a scoped read-only group, never system:masters. Labels are
      # the cluster's actual labels rather than "*":"*" -- a wildcard here
      # would silently pick up any future cluster, which is exactly what
      # least privilege is supposed to prevent.
      kubernetes_labels = {
        env  = ["prod"]
        team = ["platform"]
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

# metadata/spec, not the top-level name/roles: those are deprecated in favour
# of the standard resource shape as of provider v18.4.
resource "teleport_bot" "demo_traffic" {
  metadata = {
    name        = "demo-traffic"
    description = "IAC: unattended traffic generator for the SIEM baseline"
  }
  spec = {
    roles = [teleport_role.demo_traffic.metadata.name]
    # Shortest practical: this identity exists only for the length of a run,
    # and max_session_ttl is evaluated as the most restrictive across roles.
    max_session_ttl = "1h0m0s"
  }
}

# ONE TOKEN PER RUNNER. A bound_keypair token binds exactly one keypair: once
# the first host has joined, a second host presenting its own key is refused
# with "could not lookup signer for public key ... no matching key found",
# even though it has the right registration secret. recovery.limit lets the
# SAME key re-join after losing its identity; it does not admit a new one.
#
# ct104 is the durable runner (always-on, on the LAN). macbook is kept for
# interactive work.
variable "traffic_runners" {
  description = "Hosts that run the traffic generator. Each gets its own bound_keypair token against the shared bot."
  type        = list(string)
  default     = ["macbook", "ct104"]
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
    roles = ["Bot"]
    # .metadata.name, not .name -- the top-level attribute is deprecated and
    # comes back EMPTY once the resource uses metadata/spec, which fails at
    # apply with `token with role "Bot" must set bot_name`.
    bot_name    = teleport_bot.demo_traffic.metadata.name
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

# Additional runners beyond the first. The original `demo-traffic` token above
# stays as-is because it is already bound to the macbook's key -- renaming it
# would break that binding for no gain.
resource "random_password" "runner_secret" {
  for_each = toset([for r in var.traffic_runners : r if r != "macbook"])
  length   = 48
  special  = false
}

resource "teleport_provision_token" "runner" {
  for_each = toset([for r in var.traffic_runners : r if r != "macbook"])
  version  = "v2"
  metadata = {
    name = "demo-traffic-${each.key}"
  }
  spec = {
    roles       = ["Bot"]
    bot_name    = teleport_bot.demo_traffic.metadata.name
    join_method = "bound_keypair"
    bound_keypair = {
      onboarding = {
        registration_secret = random_password.runner_secret[each.key].result
      }
      recovery = {
        limit = 20
      }
    }
  }
}

output "registration_secret" {
  description = "macbook runner. Write to the path named in the tbot config. Sensitive; never commit."
  value       = random_password.registration_secret.result
  sensitive   = true
}

output "runner_secrets" {
  description = "Per-runner onboarding secrets, keyed by runner name."
  value       = { for k, v in random_password.runner_secret : k => v.result }
  sensitive   = true
}
