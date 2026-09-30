##################################################################################
# Desktop Access — Linux desktop on Proxmox
##################################################################################
#
# Teleport's Linux Desktop Service (18.10.3+) on a hollowtree LXC, so it costs
# nothing to run. rev-tech's `modules/linux-desktop` is the AWS equivalent and
# was read first; its README still says Teleport 19 and a staging provider are
# required. Neither is true now: the feature is in v18.10.3 and the 18.11.1
# provider accepts the `LinuxDesktop` token role and the `linux_desktop_*` role
# fields (proved with a plan-only probe on 2026-09-29).
#
# Doc: https://goteleport.com/docs/enroll-resources/desktop-access/linux-desktop/
#
# PRE-FLIGHT:
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv heronwright
#   . ~/github/homelab/proxmox/vault-env.sh
#
# TWO-PHASE for a brand-new host — see modules/proxmox-teleport-host/README.md.
#
# PER-PERSON LOGINS, AND THE ONE STEP THEY NEED. The service does not create
# host users: session start calls hostuser.Lookup(login) and fails if the user
# is missing (lib/srv/desktop/x11/xsession.go in 18.11.0). So each person SSHes
# to this host ONCE, which creates their user under create_host_user_mode =
# keep, and then opens the desktop as that same login. The role that allows the
# desktop is `linux-desktop-access` in control-plane/proxmox/3-rbac.
#
# NO MFA LABEL ON THIS HOST, deliberately. `mfa-required` matches
# `teleport.dev/mfa: required`, and any role matching a node with
# create_host_user_mode unset disables host user creation for that node. That
# would break the SSH-first step above.

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

module "linux_desktop" {
  source = "../../modules/proxmox-teleport-host"

  name  = "dev-linux-desktop"
  vm_id = 113

  # DHCP, so the router registers the name. Static hosts are exactly the set
  # that does not resolve in the LAN's DNS.
  ip_address = "dhcp"

  proxy_address = var.proxy_address

  # Node for the SSH-first step that creates each person's user, LinuxDesktop
  # for the desktop itself.
  teleport_roles = ["Node", "LinuxDesktop"]

  # env=dev / team=platform: every role that matches this sets
  # create_host_user_mode = keep, which the SSH-first step depends on.
  labels = {
    env  = "dev"
    team = "platform"
    role = "desktop"
  }

  linux_desktop = {
    # Only Xfce is installed, so there is one session and no filter is needed.
    # A filter that matches nothing gives a blank screen, not an error.
  }

  # Xfce inside Xvfb wants memory. An LXC cap is a limit, not a reservation.
  cores     = 2
  memory_mb = 3072
  disk_gb   = 16

  provision_script = <<-SCRIPT
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # xfce4 ships /usr/share/xsessions/xfce.desktop, which is how Teleport
    # discovers the session. No display manager: Teleport starts the session.
    apt-get install -y -qq xfce4 xfce4-terminal xvfb dbus-x11
    # Headless container, never bring up a graphical login.
    systemctl set-default multi-user.target
    # Both are prerequisites in the doc; fail loudly here rather than at the
    # first session.
    command -v Xvfb
    ls /usr/share/xsessions/xfce.desktop
    # The agent came up before Xvfb existed; restart it so the desktop
    # service starts against a complete host.
    systemctl restart teleport
    sleep 5
    systemctl is-active teleport
  SCRIPT

  # PHASE 2 VALUE, generated ON the container by the bootstrap on 2026-09-29.
  # A public key is not a secret, so it belongs in the repo. Reprint it with
  # the read_public_key_command output; the bootstrap never overwrites it.
  initial_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEmL6XfFVNPlg/tjUbAbidxFnP1Shek4yf/EY2qqs23B"
}
