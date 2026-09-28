##################################################################################
# TERRAFORM PROVIDER BOT
##################################################################################
#
# The Machine ID bot the Teleport Terraform provider authenticates as. Pre-flight
# for any layer using that provider is:
#
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv heronwright
#
# which re-certs this bot over its bound keypair and exports TF_TELEPORT_ADDR +
# TF_TELEPORT_IDENTITY_FILE_PATH, both documented provider arguments.
#
# `tfenv heronwright`, NOT `tfenv teleport` -- this line said the latter until
# 2026-09-28 and it was wrong. tfenv derives its tbot config name from the
# cluster's FIRST DNS LABEL, and both this cluster and the decommissioned one
# were `teleport.*`, so `tfenv teleport` loads the DEAD cluster's config and
# fails with `dial tcp: lookup ...: no such host`. That reads as a broken bot
# rather than the wrong file.
#
# `tctl terraform env` is deliberately NOT used, and note this is a local
# decision against the vendor default rather than something the docs forbid:
# Teleport's own local-auth guide recommends it. It mints a bot, a role and a
# token on every run -- three admin actions -- and the same doc notes tctl will
# prompt for MFA when MFA for administrative actions is enabled, which it is
# here. Bots are exempt from that gate, so a persistent one costs zero taps.
#
# NO CIRCULAR DEPENDENCY. These are operator CRs applied through the *kubectl*
# provider, which authenticates with the k3s kubeconfig. Terraform never needs a
# Teleport credential to manage the thing that issues its Teleport credential, so
# a broken apply cannot lock us out of fixing it.
#
# `terraform-provider` is a Teleport preset role and already exists on the
# cluster; it is not declared here.

resource "kubectl_manifest" "bot_terraform" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportBotV1"
    metadata = {
      name      = "terraform-local"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      roles = ["terraform-provider"]
    }
  })
}

resource "kubectl_manifest" "token_terraform" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v2"
    kind       = "TeleportProvisionToken"
    metadata = {
      name      = "terraform-local"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      roles       = ["Bot"]
      bot_name    = "terraform-local"
      join_method = "bound_keypair"
      bound_keypair = {
        onboarding = {
          # A PUBLIC key, deliberately in the repo. Pre-registering it means no
          # registration secret exists anywhere -- not in tfvars, not in Vault,
          # not in state. Generated on the workstation with:
          #   tbot keypair create --proxy-server=teleport.heronwright.com:443 \
          #     --storage=file:///Users/dlg/.tbot/heronwright-terraform
          #
          # BOTH VALUES CORRECTED 2026-09-28. They named the decommissioned
          # cluster and its storage dir, so following this comment verbatim
          # would have written a new keypair into ~/.tbot/teleport-terraform --
          # a directory that still exists, still holds a DIFFERENT key, and is
          # bound to nothing. The storage dir must be per-cluster because
          # bound_keypair join state (bkp_state, bkp_key_history.json) is
          # per-cluster.
          #
          # It is workstation-specific: rebuild the Mac and this one line
          # changes. Recover a lost public key by re-running the command
          # WITHOUT --overwrite, which reprints the existing one. When
          # initial_public_key is set, registration_secret is ignored.
          initial_public_key = var.terraform_bot_public_key
        }
        recovery = {
          # Each tfenv re-cert after identity expiry (1h TTL) consumes one
          # recovery, so this is sized for daily terraform use, not for
          # rebuilds. tfenv skips the re-cert while the identity is fresh
          # precisely to avoid burning these.
          # 30, the ONE documented exception to the estate's baseline of 20
          # (2026-09-27). This bot lives on the workstation, which is reset far
          # more often than any server here, and every `tbot keypair create`
          # re-run or Mac rebuild burns one. Higher churn, so a higher ceiling.
          limit = 30
          mode  = "standard"
        }
      }
    }
  })
  depends_on = [kubectl_manifest.bot_terraform]
}
