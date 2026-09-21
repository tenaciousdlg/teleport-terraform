##################################################################################
# TERRAFORM PROVIDER BOT
##################################################################################
#
# The Machine ID bot the Teleport Terraform provider authenticates as. Pre-flight
# for any layer using that provider is:
#
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv teleport
#
# which re-certs this bot over its bound keypair and exports TF_TELEPORT_ADDR +
# TF_TELEPORT_IDENTITY_FILE_PATH. `tctl terraform env` is deliberately NOT used:
# it mints an ephemeral bot, role and token on every run -- three admin actions,
# three MFA taps.
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
          #   tbot keypair create --proxy-server=teleport.chrisdlg.com:443 \
          #     --storage=file:///Users/dlg/.tbot/teleport-terraform
          # It is workstation-specific: rebuild the Mac and this one line
          # changes. When set, registration_secret is ignored.
          initial_public_key = var.terraform_bot_public_key
        }
        recovery = {
          # Each tfenv re-cert after identity expiry (1h TTL) consumes one
          # recovery, so this is sized for daily terraform use, not for
          # rebuilds. tfenv skips the re-cert while the identity is fresh
          # precisely to avoid burning these.
          limit = 30
          mode  = "standard"
        }
      }
    }
  })
  depends_on = [kubectl_manifest.bot_terraform]
}
