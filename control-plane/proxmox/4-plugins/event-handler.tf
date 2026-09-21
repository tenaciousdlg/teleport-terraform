##################################################################################
# TELEPORT EVENT HANDLER -- audit export to the estate SIEM
##################################################################################
#
# Same shape as the Slack plugin in main.tf: a role, a Machine ID bot, and a
# provision token. The difference is the join method.
#
# Slack's tbot runs INSIDE k3s, so it uses the kubernetes join and stores no
# secret. The event handler runs on CT104 alongside Loki -- deliberately
# outside the cluster, so the SIEM still collects when k3s is what broke --
# and therefore cannot use an in-cluster join. bound_keypair is the strongest
# method available to it: the enrolment binds to a keypair the client holds,
# so there is no reusable bearer secret sitting in a config file.
#
# A bot rather than `tctl auth sign`: bots are exempt from the
# MFA-on-admin-actions gate, and an identity file would expire and need
# re-signing by hand.

resource "kubectl_manifest" "role_event_handler" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name      = "teleport-event-handler"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      allow = {
        rules = [
          {
            # `session` as well as `event`: the handler fetches session
            # recordings, not just the audit stream. 3-rbac's narrower
            # `event-handler` role predates this and is now unused.
            resources = ["event", "session"]
            verbs     = ["list", "read"]
          }
        ]
      }
    }
  })
}

resource "kubectl_manifest" "bot_event_handler" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportBotV1"
    metadata = {
      name      = "event-handler"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      roles = ["teleport-event-handler"]
    }
  })
  depends_on = [kubectl_manifest.role_event_handler]
}

# PRE-REGISTERED PUBLIC KEY, no secret anywhere (migrated 2026-09-21).
#
# Was `registration_secret` from a sensitive variable sourced out of Vault at
# secret/demo/teleport-event-handler. That produced the same three problems as
# the estate agent tokens did:
#   - a secret in Vault, and a copy at /etc/tbot-registration-secret
#   - a `count = var... != "" ? 1 : 0` gate, so forgetting to export the
#     variable did not fail -- it planned to DESTROY the live token, exactly
#     like the SAML connector in 3-rbac
#   - onboarding that does not survive an operator reconcile
#
# MUTABLE KEY, NOT STATIC -- and this is the part worth copying. This bot has
# `storage: {type: directory, path: /var/lib/tbot}`, so its keypair lives in
# bot storage and `tbot keypair create --storage file:///var/lib/tbot` can
# pre-register it. Run WITHOUT --overwrite it prints the EXISTING public key
# rather than making a new one ("Existing client state found, printing
# existing public key"), so registering it here was zero-disruption: the bot
# kept its current keypair and binding and never had to re-join.
#
# That is strictly better than the static keys the estate AGENTS use in
# 3-rbac/agents.tf, which had to give up rotation and join-state verification.
# Agents only accept `static_key_path`; a bot with persistent storage keeps a
# rotatable key AND `recovery.mode = "standard"`, so join-state verification
# is retained here. Prefer --storage over --static whenever the client is a
# bot.
#
# Regenerate/recover the public key with:
#   tbot keypair create --proxy-server teleport.chrisdlg.com:443 \
#     --storage file:///var/lib/tbot
locals {
  # Public key -- in the repo on purpose. The private half never leaves
  # /var/lib/tbot on CT104.
  event_handler_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICiGLXTbm7bh4acilZQhf7H4C1udQDS6uktIaMwKuuHe"
}

# STILL A CR, DELIBERATELY. The Teleport provider would be the default (see
# ~/github/CLAUDE.md), and 3-rbac's agent tokens were converted to it. This
# layer declares only kubernetes/kubectl/helm, so adding `teleport` here would
# make EVERY plan of this layer require a bound, fresh tbot credential where
# today it requires none. That is a real operational cost and a separate
# decision from removing the secret, which is what this change is for.
# Convert when you are next changing this file for another reason.
resource "kubectl_manifest" "token_event_handler" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v2"
    kind       = "TeleportProvisionToken"
    metadata = {
      name      = "event-handler-bot"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      roles       = ["Bot"]
      bot_name    = "event-handler"
      join_method = "bound_keypair"
      bound_keypair = {
        onboarding = {
          initial_public_key = local.event_handler_public_key
        }
        recovery = {
          # `standard` keeps join-state verification, which the estate agents
          # had to abandon. Valid for a BOT: the note in
          # modules/self-database-lxc that `standard` breaks joining is about
          # AGENTS ("bound keypair joining for agents requires use of the new
          # join service"). terraform-bot.tf uses standard successfully too.
          mode = "standard"
          # Re-joins after a rebuild without minting anything new.
          limit = 5
        }
      }
    }
  })
  depends_on = [kubectl_manifest.bot_event_handler]
}
