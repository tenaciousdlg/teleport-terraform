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
#
# THIS USES THE WRONG ONBOARDING AND SHOULD BE MIGRATED. ~/github/CLAUDE.md's
# standing default is `initial_public_key`, NOT `registration_secret`, and the
# reason is exactly what this file demonstrates: "a public key is not a secret,
# so the token is fully described in the repo with nothing gitignored and
# nothing in Vault."
#
# One wrong choice here produced all of the following:
#   - a Vault entry (secret/demo/teleport-agent-join) that need not exist
#   - a sensitive TF var with no default, so a bare plan dies with
#     "Invalid index ... each.key is \"lgm\"" -- which reads like a bug in the
#     for_each and is actually an unexported variable
#   - this layer being effectively target-apply-only for anyone who has not
#     exported it
#   - per CLAUDE.md, onboarding that does NOT survive an operator reconcile:
#     a re-arm resets the token to awaiting a secret the agent already
#     consumed, whereas a pre-registered public key just re-binds
#
# MIGRATION, per the bound_keypair static-keys doc. Not yet done, deliberately:
#   1. on the host:  tbot keypair create --proxy-server <proxy>:443 \
#                      --static --static-key-path /etc/teleport-static-key
#      It prints the public key in SSH authorized_keys format.
#   2. here:  onboarding.initial_public_key = "ssh-ed25519 ..."  (in the repo;
#      it is a public key) and recovery.mode = "insecure" -- which the doc
#      requires for static keys, and which contradicts the note elsewhere in
#      CLAUDE.md that mode must be unset. That note came from `standard`
#      failing, not from testing `insecure`.
#   3. on the host: replace join_params.bound_keypair.registration_secret_path
#      with static_key_path, then restart teleport.
#
# WHY IT IS NOT DONE HERE. Two honest blockers, both worth clearing before
# anyone tries:
#   - The doc covers INITIAL joining only. It does not describe converting an
#     agent that has already joined with a registration secret, so this is
#     unproven on a live agent. Rollback does exist: the secrets remain in
#     Vault and on the hosts at /etc/teleport-join-secret.
#   - lgm has no passwordless sudo, and steps 1 and 3 need root. siem (CT104)
#     is reachable as root via `ssh hollowtree` + `pct exec 104`, so siem is
#     the natural proving ground; do it there first, confirm the agent
#     re-joins, and only then touch lgm.
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
