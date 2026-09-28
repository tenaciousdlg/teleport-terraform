##################################################################################
# Application Access — HTTPBin on Proxmox
##################################################################################
#
# The homelab counterpart to application-access-httpbin, whose README says it
# "Deploys an HTTPBin instance on EC2". EC2 was the substrate, not the demo.
#
# PRE-FLIGHT:
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv heronwright
#   . ~/github/homelab/proxmox/vault-env.sh
#
# TWO-PHASE for a new host — see modules/proxmox-teleport-host/README.md.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    teleport = { source = "terraform.releases.teleport.dev/gravitational/teleport", version = "~> 18.0" }
    proxmox  = { source = "bpg/proxmox", version = "~> 0.66" }
  }
}

provider "teleport" {}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
  ssh { agent = true }
}

module "httpbin" {
  source = "../../modules/proxmox-teleport-host"

  name       = "dev-httpbin"
  vm_id      = 109
  ip_address = "192.168.1.56/24"

  proxy_address = var.proxy_address

  # Node AND App. A Node-only token makes the App registration fall back to the
  # legacy join path and fail with a message that reads like a capability
  # problem and is actually a missing role.
  teleport_roles = ["Node", "App"]

  labels = {
    env  = "dev"
    team = "platform"
    role = "app"
  }

  apps = [{
    name = "httpbin"
    # Loopback: the app is reached THROUGH Teleport, so binding it on the LAN
    # would add an unauthenticated path to the same service.
    uri = "http://127.0.0.1:8080"
  }]

  cores     = 1
  memory_mb = 512
  disk_gb   = 8

  # gunicorn + httpbin from apt/pip rather than a container: this LXC is
  # unprivileged and nesting a container runtime inside it to serve one Flask
  # app is more moving parts than the demo needs. Debian 13 enforces PEP 668,
  # so a venv is required — `pip install` into the system interpreter is
  # refused with "externally-managed-environment", which reads like a
  # permissions error and is not.
  provision_script = <<-SH
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq python3 python3-venv
    python3 -m venv /opt/httpbin
    /opt/httpbin/bin/pip install --quiet --upgrade pip
    /opt/httpbin/bin/pip install --quiet httpbin gunicorn
    cat > /etc/systemd/system/httpbin.service <<'UNIT'
    [Unit]
    Description=httpbin behind Teleport Application Access
    After=network-online.target
    Wants=network-online.target
    [Service]
    ExecStart=/opt/httpbin/bin/gunicorn -b 127.0.0.1:8080 httpbin:app
    Restart=always
    RestartSec=5
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now httpbin
    sleep 3
    curl -sf --max-time 10 http://127.0.0.1:8080/status/200 >/dev/null && echo "httpbin responding"
  SH

  # PHASE 2 VALUE, generated ON the container. A public key is not a secret,
  # which is what keeps any onboarding secret out of terraform state.
  initial_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFfETwb/IqtBidylH4uGwb04LYSc71Tt5x9uO9884w1i"
}
