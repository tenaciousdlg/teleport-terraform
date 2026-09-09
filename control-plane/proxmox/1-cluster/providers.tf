##################################################################################
# PROVIDERS
##################################################################################
#
# This is the one genuinely new layer vs. the EKS control plane: it stands up a
# single-node k3s cluster inside a PRIVILEGED LXC container on the `hollowtree`
# Proxmox node (reworked from a VM — containers preferred where feasible) and
# installs k3s via `pct exec`. Everything downstream (2-teleport, 3-rbac,
# 4-plugins) then talks to k3s exactly the way the EKS layers talked to EKS.

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Credentials come from PROXMOX_VE_* env vars OR the vars below. The vars default
# to null so that leaving them unset falls through to the provider's env-var
# DefaultFuncs (PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN / PROXMOX_VE_INSECURE).
# Never hardcode the API token — set TF_VAR_proxmox_api_token or PROXMOX_VE_API_TOKEN.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # bpg needs SSH to the node for some container operations, and — more to the
  # point here — our null_resources SSH the node to append the raw `lxc.*` keys
  # to /etc/pve/lxc/<vmid>.conf and to run the k3s install via `pct exec` (the
  # provider has no passthrough for arbitrary lxc.* keys). The Proxmox API token
  # alone is not enough for those. `agent = true` uses the caller's ssh-agent;
  # set PROXMOX_VE_SSH_* or an ssh{} username/key here if no agent is loaded.
  ssh {
    agent = true
  }
}
