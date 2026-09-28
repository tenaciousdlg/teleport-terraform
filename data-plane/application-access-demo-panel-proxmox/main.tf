##################################################################################
# Application Access — Demo Panel on Proxmox
##################################################################################
#
# The homelab counterpart to application-access-demo-panel, a Flask identity
# panel that decodes the JWT Teleport presents so an audience can SEE the
# assertion rather than take it on trust. EC2 was the substrate.
#
# The app is public (tenaciousdlg/app-demo-panel) and its requirements are two
# lines, so it is cloned rather than vendored.
#
# PRE-FLIGHT:
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv heronwright
#   . ~/github/homelab/proxmox/vault-env.sh

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

module "demo_panel" {
  source = "../../modules/proxmox-teleport-host"

  name       = "dev-panel"
  vm_id      = 111
  ip_address = "192.168.1.58/24"

  proxy_address  = var.proxy_address
  teleport_roles = ["Node", "App"]

  labels = {
    env  = "dev"
    team = "platform"
    role = "app"
  }

  apps = [{
    name = "demo-panel"
    uri  = "http://127.0.0.1:5000"
  }]

  cores     = 1
  memory_mb = 512
  disk_gb   = 8

  # Loopback bind, unlike the AWS module's 0.0.0.0:5000. There the security
  # group was the boundary; here the app is reached only through Teleport, and
  # binding the LAN would add an unauthenticated path to a page that displays
  # decoded identity assertions.
  #
  # venv because Debian 13 enforces PEP 668 — `pip install` into the system
  # interpreter is refused with "externally-managed-environment", which reads
  # like a permissions problem and is not.
  provision_script = <<-SH
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq git python3 python3-venv

    if [ ! -d /opt/demo-panel/.git ]; then
      git clone --depth 1 https://github.com/tenaciousdlg/app-demo-panel /opt/demo-panel
    else
      git -C /opt/demo-panel pull --ff-only
    fi

    python3 -m venv /opt/demo-panel/.venv
    /opt/demo-panel/.venv/bin/pip install --quiet --upgrade pip
    /opt/demo-panel/.venv/bin/pip install --quiet -r /opt/demo-panel/requirements.txt

    cat > /etc/systemd/system/demo-panel.service <<'UNIT'
    [Unit]
    Description=Teleport demo panel (JWT decoder) behind Application Access
    After=network-online.target
    Wants=network-online.target
    [Service]
    WorkingDirectory=/opt/demo-panel
    ExecStart=/opt/demo-panel/.venv/bin/gunicorn -w 2 -b 127.0.0.1:5000 app:app
    Restart=always
    RestartSec=5
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now demo-panel
    sleep 4
    curl -sf --max-time 10 -o /dev/null http://127.0.0.1:5000/ && echo "demo-panel responding"
  SH

  # PHASE 2 VALUE, generated ON the container. Not a secret, so it lives here
  # rather than as an onboarding secret in terraform state.
  initial_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPmU1gYBtWzeQnX7oviVNYsM4vx3dBfFFcmcAi9Bmg++"
}
