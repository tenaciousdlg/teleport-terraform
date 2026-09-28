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
      # `prod`, not `home`. Fixed 2026-09-27: the estate's apps were retagged
      # from `env: home` to `env: prod` earlier the same day, and this selector
      # was missed, so the role matched no app at all and the bot's two
      # application tunnels failed forever with `app "grafana" not found` --
      # an RBAC miss that reads like a missing resource.
      #
      # IT WAS MISSED FOR A STRUCTURAL REASON WORTH KEEPING. The retag was done
      # carefully, with the dependent roles widened before the flip and
      # narrowed after. Every role it checked lived in the control-plane
      # layers. This one lives in a data-plane layer whose state still
      # described the destroyed cluster, so it was invisible to a search of
      # what was applied. A label retag's blast radius is every layer that
      # SELECTS on that label, not every layer that was applied recently.
      app_labels = {
        "env" = ["prod", "dev"]
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

# PRE-REGISTERED PUBLIC KEYS, NOT REGISTRATION SECRETS. Converted 2026-09-27.
#
# Both runners already held a bound keypair in their tbot storage, so their
# PUBLIC halves are simply registered here and each bot re-binds with the key
# it already has. That is the same zero-disruption conversion the event handler
# had in 4-plugins, and it is the repo default (~/github/CLAUDE.md): a public
# key is not a secret, so the token is fully described in this file with
# nothing gitignored, nothing in Vault, and nothing to write to the runner.
#
# It also removed work rather than adding it. The alternative, applying the old
# `registration_secret` form against the new cluster, meant generating a secret
# into terraform STATE and then copying it onto CT104 at
# /etc/demo-traffic/secret. Pre-registering skips the secret entirely.
#
# Recover either value without changing it by re-running `tbot keypair create`
# against the matching --storage path WITHOUT --overwrite; it reprints the
# existing key.
locals {
  # macbook: ~/.tbot/demo-traffic
  # ct104:   /var/lib/demo-traffic/store
  runner_public_keys = {
    macbook = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMhJvnN7LOaVLH+53bePwLL6eEi+aeUbqtMEJDXq6Ssx"
    ct104   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPSz0EY+STUg93n0cTvVBpjDI8nzCNpqVbjZs+h+X/uq"
  }
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
        initial_public_key = local.runner_public_keys["macbook"]
      }
      recovery = {
        # `mode` deliberately unset. The docs state that unset enforces the
        # same rules as `standard` (recovery limit and join-state both
        # verified), so this is not a weaker setting, and it avoids relitigating
        # the agent-vs-bot confusion recorded in modules/self-database-lxc.
        limit = 20
      }
    }
  }
}

# Additional runners beyond the first. The original `demo-traffic` token above
# keeps its name because it is the macbook's -- renaming it would rebind for no
# gain.
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
        initial_public_key = local.runner_public_keys[each.key]
      }
      recovery = {
        limit = 20
      }
    }
  }
}

# OUTPUTS REMOVED 2026-09-27 with the registration secrets they carried:
# `registration_secret` and `runner_secrets`. There is no onboarding secret any
# more, so there is nothing to hand to a runner and nothing sensitive for this
# layer to emit. Deleting them is most of the point of the conversion: the
# secrets existed only to be copied onto a host, and each copy was another
# place the value lived.
#
# What replaces them is `runner_public_keys` above, which is checked in.

output "runner_public_keys" {
  description = "Pre-registered public half per runner. Not sensitive -- in the repo on purpose."
  value       = local.runner_public_keys
}
