##################################################################################
# ESTATE AGENT JOIN TOKENS
##################################################################################
#
# Join tokens for the Teleport agents running on personal estate machines that
# are NOT part of the k3s cluster -- today `lgm` (the WSL box, AI stack) and
# `siem` (CT104, Loki/Grafana). Anything inside k3s uses the kubernetes join
# and needs no token at all; these two cannot, because they are deliberately
# outside it.
#
# join_method is `bound_keypair`: the standing default whenever a stronger
# platform attestation is unavailable. The enrolment binds to a keypair the
# agent generates and holds, so unlike a static token there is no reusable
# bearer secret sitting in a config file on the host.
#
# Adding an estate agent is one map entry plus its secret in Vault -- the same
# shape as adding a host to the SIEM, and for the same reason: this list is
# expected to grow.
#
# NOTE: these tokens carry bound_keypair ENROLMENT STATE (the bound public
# key). Deleting and recreating the CR mints a fresh token and the agent can no
# longer re-join -- it would need re-registering by hand. Change them in place;
# do not taint them.

# The agent names are NOT secret and belong in the repo -- recording which
# estate machines hold a join token is most of the value of adopting these into
# terraform. Only the onboarding secrets come from Vault, so the two are
# separate variables (and a sensitive value cannot drive for_each anyway).
resource "kubectl_manifest" "agent_token" {
  for_each = toset(var.estate_agents)

  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v2"
    kind       = "TeleportProvisionToken"
    metadata = {
      name      = "agent-${each.key}"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      # Node + App: every estate agent both serves SSH and proxies at least one
      # local app (ollama on lgm, grafana on siem). Verified working with this
      # exact pair -- a token is scoped to the roles named here, so an agent
      # that later gains an app with only "Node" fails to start that service.
      roles       = ["Node", "App"]
      join_method = "bound_keypair"
      bound_keypair = {
        onboarding = {
          registration_secret = var.agent_registration_secrets[each.key]
        }
        recovery = {
          # Re-joins allowed after a rebuild without minting a new secret.
          # Higher than the event handler's 5: WSL gets rebuilt far more often.
          limit = 10
        }
      }
    }
  })
}
