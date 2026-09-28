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

locals {
  token_name      = "agent-${var.name}"
  static_key_path = "/var/lib/teleport-bkp/static-key"

  teleport_config = templatefile("${path.module}/teleport.yaml.tpl", {
    name            = var.name
    proxy_address   = var.proxy_address
    token_name      = local.token_name
    labels          = var.labels
    apps            = var.apps
    mcp_apps        = var.mcp_apps
    static_key_path = local.static_key_path
  })

  bootstrap = templatefile("${path.module}/bootstrap.sh.tpl", {
    proxy_address    = var.proxy_address
    static_key_path  = local.static_key_path
    teleport_version = var.teleport_version
  })
}

# ---- Token -------------------------------------------------------------------
#
# initial_public_key, NOT registration_secret. A public key is not a secret, so
# the token is fully described in the repo with nothing in terraform state.
resource "teleport_provision_token" "agent" {
  version = "v2"
  metadata = {
    name        = local.token_name
    description = "IAC: bound_keypair join for the ${var.name} agent host"
    labels      = var.labels
  }
  spec = {
    roles       = var.teleport_roles
    join_method = "bound_keypair"
    bound_keypair = {
      onboarding = {
        initial_public_key = var.initial_public_key
      }
      recovery = {
        # `insecure` is REQUIRED for a STATIC key and is not a weaker choice
        # made for convenience. The static-key guide states it outright: a
        # static key keeps no mutable join state, so join-state verification
        # fails on every rejoin without it. agent-lgm and agent-siem are the
        # same shape.
        #
        # `limit` is therefore INERT here — insecure mode ignores it — which is
        # why no number is set rather than setting one that implies a control
        # that is not applied. Static keys also CANNOT rotate, so never add
        # rotate_after.
        mode = "insecure"
      }
    }
  }
}

# ---- Container ---------------------------------------------------------------

resource "proxmox_virtual_environment_container" "host" {
  node_name     = var.proxmox_node
  vm_id         = var.vm_id
  unprivileged  = true
  start_on_boot = true

  initialization {
    hostname = var.name
    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }
  }

  cpu { cores = var.cores }
  memory { dedicated = var.memory_mb }

  disk {
    # `ember`, the ZFS pool the guests actually live on. NOT "local-zfs" —
    # that is the Proxmox default name and does not exist here; assuming it
    # fails at create with `storage 'local-zfs' does not exist`, which is
    # clear but only after the fact. Verified against `pvesm status` and
    # against what CT105 and CT107 use.
    datastore_id = var.datastore_id
    size         = var.disk_gb
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "debian"
  }

  features { nesting = true }

  lifecycle {
    # template_file_id reads back EMPTY after any refresh, because the Proxmox
    # API does not report which template a container came from. Without this a
    # plan proposes replacing a running container for no change.
    ignore_changes = [operating_system]
  }
}

# ---- Bootstrap: Teleport + the static keypair --------------------------------
#
# terraform_data, not null_resource, per the estate default.
resource "terraform_data" "bootstrap" {
  depends_on = [proxmox_virtual_environment_container.host]

  triggers_replace = {
    vm_id  = var.vm_id
    script = sha256(local.bootstrap)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      T=$(mktemp)
      cat > "$T" <<'BOOTSTRAP'
      ${local.bootstrap}
      BOOTSTRAP
      scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$T" '${var.proxmox_ssh}:/tmp/bootstrap-${var.name}.sh'
      rm -f "$T"
      ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 '${var.proxmox_ssh}' \
        "set -e
         for i in \$(seq 1 20); do pct exec ${var.vm_id} -- true 2>/dev/null && break; sleep 3; done
         pct push ${var.vm_id} /tmp/bootstrap-${var.name}.sh /root/bootstrap.sh --perms 0700
         rm -f /tmp/bootstrap-${var.name}.sh
         pct exec ${var.vm_id} -- /root/bootstrap.sh"
    EOT
  }
}

# ---- Agent config + optional payload -----------------------------------------

resource "terraform_data" "agent_config" {
  depends_on = [terraform_data.bootstrap, teleport_provision_token.agent]

  triggers_replace = {
    config = sha256(local.teleport_config)
    extra  = sha256(var.provision_script)
    token  = local.token_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      C=$(mktemp)
      cat > "$C" <<'TPCONF'
      ${local.teleport_config}
      TPCONF
      scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$C" '${var.proxmox_ssh}:/tmp/teleport-${var.name}.yaml'
      rm -f "$C"
      ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 '${var.proxmox_ssh}' \
        "set -e
         pct push ${var.vm_id} /tmp/teleport-${var.name}.yaml /etc/teleport.yaml --perms 0600
         rm -f /tmp/teleport-${var.name}.yaml
         pct exec ${var.vm_id} -- systemctl enable teleport
         pct exec ${var.vm_id} -- systemctl restart teleport
         sleep 10
         pct exec ${var.vm_id} -- systemctl is-active teleport"
    EOT
  }
}

# ---- Payload -----------------------------------------------------------------
#
# Whatever this host actually serves. Runs AFTER the agent is up, so a failure
# here leaves a reachable host to debug on rather than an invisible one.
#
# Delivered with scp + `pct push` and then executed, never piped to
# `pct exec` stdin. PATH is exported for the same reason the bootstrap does it:
# `pct exec` omits /usr/local/bin.
resource "terraform_data" "payload" {
  count      = var.provision_script != "" ? 1 : 0
  depends_on = [terraform_data.agent_config]

  triggers_replace = {
    vm_id  = var.vm_id
    script = sha256(var.provision_script)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      P=$(mktemp)
      {
        echo '#!/usr/bin/env bash'
        echo 'export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
        cat <<'PAYLOAD'
      ${var.provision_script}
      PAYLOAD
      } > "$P"
      scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$P" '${var.proxmox_ssh}:/tmp/payload-${var.name}.sh'
      rm -f "$P"
      ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 '${var.proxmox_ssh}' \
        "set -e
         pct push ${var.vm_id} /tmp/payload-${var.name}.sh /root/payload.sh --perms 0700
         rm -f /tmp/payload-${var.name}.sh
         pct exec ${var.vm_id} -- /root/payload.sh"
    EOT
  }
}
