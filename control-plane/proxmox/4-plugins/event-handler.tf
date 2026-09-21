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

resource "kubectl_manifest" "token_event_handler" {
  count = var.event_handler_registration_secret != "" ? 1 : 0
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
          registration_secret = var.event_handler_registration_secret
        }
        recovery = {
          # Allows re-joining after a rebuild without minting a new secret.
          limit = 5
        }
      }
    }
  })
  depends_on = [kubectl_manifest.bot_event_handler]
}
