##################################################################################
# MCP Access — stdio filesystem server on Proxmox
##################################################################################
#
# The homelab counterpart to machine-id-mcp, whose README says it "Deploys a
# Teleport Application Service running a stdio-based MCP server". The EC2 was
# the substrate.
#
# HOW STDIO MCP DIFFERS FROM AN ORDINARY APP, and it is the whole reason this
# host exists separately: there is no `uri` and nothing is listening. Teleport
# LAUNCHES the command on demand and proxies stdio between the client and it.
# So `run_as_host_user` is required — it is the account the command runs as —
# and the app will not start without one.
#
# ACCESS: needs the `mcp-user` preset role, or a role allowing app_labels
# `teleport.internal/app-sub-kind: mcp` together with `mcp.tools`. Without it
# the app registers fine and is simply invisible, which reads as a broken
# registration.
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

module "mcp" {
  source = "../../modules/proxmox-teleport-host"

  name       = "dev-mcp"
  vm_id      = 110
  ip_address = "192.168.1.57/24"

  proxy_address  = var.proxy_address
  teleport_roles = ["Node", "App"]

  labels = {
    env  = "dev"
    team = "platform"
    role = "mcp"
  }

  mcp_apps = [{
    name = "mcp-filesystem"
    # VERIFIED against `ls /opt/mcp/bin`, not assumed. npm names this binary
    # `mcp-server-filesystem`, not `server-filesystem`, and the first version of
    # this file guessed the shorter name — Teleport would have registered the
    # app happily and then failed to launch anything on first use.
    command = "/opt/mcp/bin/mcp-server-filesystem"
    # Scoped to one directory ON PURPOSE. The filesystem server exposes exactly
    # what it is pointed at, so pointing it at / would hand every tool call the
    # whole container.
    args             = ["/srv/mcp-files"]
    run_as_host_user = "mcp"
  }]

  cores     = 1
  memory_mb = 768
  disk_gb   = 8

  # node is installed from the distro rather than npx-at-runtime: npx resolves
  # and downloads on every invocation, so the MCP server would fail whenever
  # the registry is unreachable, and Teleport launches this command on demand
  # rather than at boot — the failure would surface to a user mid-session.
  provision_script = <<-SH
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq nodejs npm

    id -u mcp >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin mcp

    npm install --global --silent --prefix /opt/mcp @modelcontextprotocol/server-filesystem
    # npm --prefix puts binaries in <prefix>/bin; make sure the name matches
    # what the app config launches, or Teleport starts a command that is not there.
    ls -l /opt/mcp/bin/ || true

    install -d -o mcp -g mcp -m 0755 /srv/mcp-files
    cat > /srv/mcp-files/README.md <<'DEMO'
    # Demo corpus

    Files the MCP filesystem server can see. Scoped to this directory only.
    DEMO
    printf 'service,owner,tier\nanalytics,data-team,gold\nbilling,platform,silver\n' > /srv/mcp-files/services.csv
    chown -R mcp:mcp /srv/mcp-files
    echo "mcp payload done"
  SH

  # PHASE 2 VALUE, generated ON the container. A public key is not a secret,
  # which is what keeps any onboarding secret out of terraform state.
  initial_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILZ6POy4aPwuy3oyIxLXcLMKxZb8KcJNJdW2eqL7R0N/"
}
