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
# platform attestation is unavailable.
#
# NOTHING HERE IS SECRET AND NOTHING COMES FROM VAULT (migrated 2026-09-21).
# These tokens previously used `registration_secret`, which meant a 48-byte
# secret per agent in Vault at secret/demo/teleport-agent-join, a sensitive
# terraform variable with no default, and a layer that could not be planned
# without it -- a bare plan died with `Invalid index ... each.key is "lgm"`,
# which reads like a for_each bug and is an unexported variable. Every one of
# those problems came from that single choice.
#
# ~/github/CLAUDE.md's standing default says why: "a public key is not a
# secret, so the token is fully described in the repo with nothing gitignored
# and nothing in Vault." The public keys below are exactly that.
#
# WHAT STATIC KEYS ACTUALLY COST, stated precisely, because it is easy to
# overstate. bound_keypair's central property is preserved either way: there
# is NO reusable bearer token. Both flavours also keep a private key on disk
# -- the agent-generated one lives in /var/lib/teleport -- so "secret on disk"
# is not the difference, and the previous setup was worse on that axis anyway
# (a 48-byte registration secret at /etc/teleport-join-secret AND a copy in
# Vault). The two real losses, both stated by `tbot keypair create` itself:
#   - NO KEYPAIR ROTATION. If a rotation is ever requested server-side via the
#     token's `rotate_after` field, the agent cannot join. Do not set
#     `rotate_after` on these tokens.
#   - NO JOIN-STATE VERIFICATION, because `recovery.mode` must be "insecure".
#     A static key keeps no mutable join state, so `recovery_count` and
#     instance binding are not checked on rejoin -- that is the clone-and-
#     replay detection being given up, not confidentiality of the key.
#
# WHY THIS SURVIVES THE OPERATOR. A reconcile wipes `bound_public_key`,
# `bound_bot_instance_id` and `recovery_count`. With a pre-registered public
# key the agent simply re-binds on its next join. A `registration_secret` does
# not survive that, because the re-arm resets the token to awaiting a secret
# the agent already consumed -- which is the failure this whole migration
# removes.
#
# NOTE: these tokens carry bound_keypair ENROLMENT STATE. Change them in
# place; do not taint them.

# WHY THE PROVIDER AND NOT A CR (converted 2026-09-21). ~/github/CLAUDE.md:
# "Default for Teleport-native resources: the Teleport Terraform provider",
# and "convert an old one only when you are already changing it" -- which this
# is. `teleport_provision_token` expresses everything needed here, confirmed
# against `terraform providers schema -json`:
#   bound_keypair.onboarding = [initial_public_key, must_register_before,
#                               registration_secret]
#   bound_keypair.recovery   = [limit, mode]
# The previous kubectl_manifest form was copied from token_terraform in this
# same layer, which predates the provider decision.
#
# Conversion deletes the CR, which deletes the live Teleport token, then
# recreates it through the provider. That window is safe for a JOIN token
# specifically: a running agent authenticates with its existing identity and
# only needs the token to re-join. Do not do this while an agent is restarting.

# WHY THE KEYPAIR IS STILL GENERATED ON THE HOST, and not with
# `tls_private_key`. Terraform could generate an ED25519 key and hand
# `public_key_openssh` straight to initial_public_key -- the formats line up
# exactly, and `private_key_pem` is the PKCS#8 PEM that static_key_path wants.
# It is still the wrong call here: the private key would then live in
# terraform.tfstate, and this layer uses `backend "local"`, so that is a
# plaintext private key sitting in a file on the Mac. That recreates the exact
# problem this migration removes -- a secret needing somewhere to live -- and
# merely moves it from Vault to state. Generating on the host means the
# private key exists in exactly one place and never travels; only the public
# key enters the repo, which is what makes the token fully described here.
locals {
  # IN THE REPO ON PURPOSE. These are public keys -- the private halves live
  # only at /etc/teleport-static-key on each host, mode 0600, root-owned, and
  # never leave it. Regenerate one with:
  #
  #   tbot keypair create --proxy-server teleport.chrisdlg.com:443 \
  #     --static --static-key-path /etc/teleport-static-key
  #
  # Re-running without --overwrite reprints the existing public key rather
  # than replacing it, which is how you recover this value if it is lost.
  #
  # Every name here must also appear in var.estate_agents; the for_each below
  # is driven by that list, so adding a machine is one entry in each.
  agent_public_keys = {
    lgm  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB+GNoDZpHlhRD+wDFmudYojM2/HJyg+91nDnmOmd+ag"
    siem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILzC1ErGUkrFXf/s4tCl/DJNyWXiIhFHTXSZoFKtvcP0"
  }
}

# The agent names are NOT secret and belong in the repo -- recording which
# estate machines hold a join token is most of the value of adopting these
# into terraform.
resource "teleport_provision_token" "agent" {
  for_each = toset(var.estate_agents)

  version = "v2"
  metadata = {
    name        = "agent-${each.key}"
    description = "IAC: bound_keypair join for the ${each.key} estate agent"
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
        # Indexed, not looked up with a default: fails loudly if a name is in
        # estate_agents but missing a key, rather than rendering an empty
        # onboarding block that would look applied and leave the agent unable
        # to join.
        initial_public_key = local.agent_public_keys[each.key]
      }
      recovery = {
        # REQUIRED for static keys -- `tbot keypair create` says so outright:
        # "'insecure' recovery mode must be used". A static key keeps no
        # mutable join state, so join-state verification would fail on every
        # rejoin. `limit` is ignored in this mode; kept for when these move
        # back to mutable keys.
        mode  = "insecure"
        limit = 10
      }
    }
  }
}
