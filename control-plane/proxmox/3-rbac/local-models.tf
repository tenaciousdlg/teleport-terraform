# local-models.tf — the workstation's always-on path to lgm's local models.
#
# WHY. Personal sessions must not reach Beams (CTO, 2026-10-13), and after the
# 16 Oct cutover they need a backend of their own: lgm's Ollama. It is already
# published to this cluster as the `ollama` app by the agent on lgm
# (data-plane/estate-agents), and Ollama has NO auth of its own, so Teleport
# RBAC is the only thing in front of it.
#
# HOW. A tbot on the workstation runs an `application-tunnel` service, a local
# listener on 127.0.0.1:11434 that forwards to `ollama`, so a harness points at
# http://127.0.0.1:11434 as if Ollama were local. Same shape as prism, which
# does this for Beams. Doc:
# https://goteleport.com/docs/reference/machine-workload-identity/configuration.md
# (application-tunnel). It is unauthenticated on the local side by design, so it
# listens on loopback only.
#
# PATTERN: usage-exporter.tf (role/bot/bound_keypair token); terraform-local for
# a workstation-generated key.

resource "teleport_role" "local_model_client" {
  version = "v7"
  metadata = {
    name        = "local-model-client"
    description = "IAC: the workstation's tunnel to lgm's Ollama, that app only"
    labels = {
      env  = "prod"
      team = "platform"
      role = "inference"
    }
  }

  spec = {
    allow = {
      # `role: inference` is carried by `ollama` alone (checked against every
      # app_server on the cluster, 2026-10-14). Add a second inference app
      # and this role reaches it too, which is the intent.
      app_labels = {
        role = ["inference"]
      }
    }
    options = {
      max_session_ttl = "1h"
    }
  }
}

resource "teleport_bot" "local_model_client" {
  metadata = {
    name = "local-model-client"
  }
  spec = {
    roles = [teleport_role.local_model_client.metadata.name]
  }

  depends_on = [teleport_role.local_model_client]
}

resource "teleport_provision_token" "local_model_client" {
  version = "v2"
  metadata = {
    name        = "local-model-client"
    description = "IAC: bound_keypair join for the workstation's Ollama tunnel"
  }
  spec = {
    roles       = ["Bot"]
    bot_name    = teleport_bot.local_model_client.metadata.name
    join_method = "bound_keypair"
    bound_keypair = {
      onboarding = {
        # Generated on the workstation, never by terraform:
        #   tbot keypair create --proxy-server teleport.heronwright.com:443 \
        #     --storage file://$HOME/.tbot/heronwright-ollama
        # Workstation-specific: a new Mac generates its own and this changes.
        initial_public_key = var.local_model_client_public_key
      }
      recovery = {
        # `standard`: agent-generated key with join state, as usage-exporter.tf.
        # The limit is measured against status.bound_keypair.recovery_count.
        # A workstation sleeps past its 1h identity, so EVERY wake is a
        # recovery: 20 were spent 2026-10-16 to 10-20 (~6/day) and the tunnel
        # died with "no recovery attempts remaining". 1000 is ~5 months at
        # that rate; when it nears, raise it again (Chris, 2026-10-27).
        mode  = "standard"
        limit = 1000
      }
    }
  }

  depends_on = [teleport_bot.local_model_client]
}
