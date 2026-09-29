##################################################################################
# Server Access — SSH node on Proxmox
##################################################################################
#
# The homelab counterpart to server-access-ssh-getting-started, which deploys
# "a minimal AWS environment". AWS was never the demo there; it was just
# supplying a VM, and this estate has spare capacity measured at 8 cores and
# ~11 GB free with six containers holding 21.5 GB of caps against 3.5 GB of
# actual use.
#
# PRE-FLIGHT:
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv heronwright
#   . ~/github/homelab/proxmox/vault-env.sh
#
# TWO-PHASE for a brand-new host — see modules/proxmox-teleport-host/README.md.
# The token cannot reference a key that does not exist, and the key is generated
# ON the host so its private half never enters terraform state.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "~> 18.0"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "teleport" {}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
  ssh { agent = true }
}

module "ssh_node" {
  source = "../../modules/proxmox-teleport-host"

  name       = "dev-ssh"
  vm_id      = 108
  ip_address = "192.168.1.55/24"

  proxy_address = var.proxy_address

  # Node only. No app_service on this host, so an App role would grant more
  # than the config uses.
  teleport_roles = ["Node"]

  # env + team + role, the estate convention measured across the templates.
  # env=dev keeps it matched by platform-dev-access rather than the prod roles.
  #
  # THE MFA LABEL IS ADDED HERE AND NOWHERE ELSE, and that is forced rather
  # than chosen. A node's labels come from `ssh_service.labels` in its own
  # /etc/teleport.yaml, so the agent re-announces them on every heartbeat.
  # There is no `tctl` path at all: `tctl update` in 18.11 supports exactly one
  # resource type, `remote_cluster`, and refuses `node` outright. Anything set
  # out of band would be overwritten by the next heartbeat even if it were
  # accepted.
  labels = merge(
    {
      env  = "dev"
      team = "platform"
      role = "server"
    },
    var.require_mfa ? { "teleport.dev/mfa" = "required" } : {},
  )

  # Deliberately small. This host exists to be SSHed into; it serves nothing.
  cores     = 1
  memory_mb = 512
  disk_gb   = 8

  # PHASE 2 VALUE, generated ON the container by the bootstrap and pasted here.
  # A public key is not a secret, so it belongs in the repo: that is what keeps
  # any onboarding secret out of terraform state entirely.
  #
  # Reprint it any time with `tbot keypair create` WITHOUT --overwrite; it logs
  # that an existing key was found and prints the same value.
  initial_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII6Ypwkzrw7zoo20GibKE0QnIUxHrLQYqjFO/pF3pZPW"
}
