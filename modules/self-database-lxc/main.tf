##################################################################################
# SELF-HOSTED DATABASE ON A PROXMOX LXC
##################################################################################
#
# The LXC counterpart to modules/self-database, which is EC2-shaped. Same
# interface and the same TLS story; only the compute changes, so the data-plane
# vignettes can point at either.
#
# Why this exists: the Teleport control plane moved to a self-hosted cluster,
# and a database demo does not need a cloud provider. The agent dials OUT to the
# proxy like any other, so where it runs is irrelevant to the cluster.
#
# The engine and the Teleport agent share one container: the database listens on
# localhost only and the agent reaches it there, so the engine is never exposed
# on the LAN at all. That is why the vignette registers it with uri
# "localhost:5432".

terraform {
  required_providers {
    teleport = {
      source = "terraform.releases.teleport.dev/gravitational/teleport"
    }
    proxmox = {
      source = "bpg/proxmox"
    }
    tls = {
      source = "hashicorp/tls"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

locals {
  name = "${var.env}-${var.db_type}"
  port = var.db_type == "postgres" ? 5432 : 3306
}

# ---- TLS: private CA, server cert ------------------------------------------
# Mirrors modules/self-database. The engine presents a cert from this CA, and
# Teleport is told to trust it via the vignette's dynamic registration
# (ca_cert_chain). Client auth runs the other way: the engine's ssl_ca_file also
# contains Teleport's db-client CA, so certs Teleport presents validate.

resource "tls_private_key" "ca_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca_cert" {
  private_key_pem = tls_private_key.ca_key.private_key_pem
  subject {
    common_name  = "example"
    organization = "example"
  }
  validity_period_hours = 87600
  is_ca_certificate     = true
  allowed_uses          = ["cert_signing", "client_auth", "server_auth", "key_encipherment", "digital_signature"]
}

resource "tls_private_key" "server_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server_csr" {
  private_key_pem = tls_private_key.server_key.private_key_pem
  subject {
    common_name  = var.db_hostname
    organization = "example"
  }
  dns_names = [var.db_hostname, "localhost", "127.0.0.1"]
}

resource "tls_locally_signed_cert" "server_cert" {
  cert_request_pem      = tls_cert_request.server_csr.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca_key.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours = 8760
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth", "client_auth"]
}

# ---- Join --------------------------------------------------------------------
# bound_keypair, per the standing default: there is no platform attestation for
# an LXC, and this is the strongest method left. The agent generates its keypair
# on first join and binds it, so after enrolment there is no reusable secret on
# the host.
#
# The onboarding secret is generated here rather than pre-registering a public
# key: a brand-new container has no keypair to pre-register. It lives in
# terraform state (already sensitive) and never touches the repo or Vault.

resource "random_password" "registration_secret" {
  length  = 48
  special = false
}

resource "teleport_provision_token" "db" {
  version = "v2"
  metadata = {
    name = "db-${local.name}"
  }
  spec = {
    # Db AND Node, matching modules/self-database. The config enables
    # ssh_service as well as db_service, so the process registers a Node
    # identity too -- with a Db-only token that registration falls back to the
    # legacy join path and dies with "bound keypair joining for agents requires
    # use of the new join service", which reads like a capability problem and
    # is actually a missing role.
    roles       = ["Db", "Node"]
    join_method = "bound_keypair"
    bound_keypair = {
      onboarding = {
        registration_secret = random_password.registration_secret.result
      }
      recovery = {
        # Sized for container rebuilds, not for routine operation -- a running
        # agent renews its identity and never spends one of these.
        #
        # `mode` is deliberately UNSET. Setting it to "standard" makes an agent
        # join fail with "bound keypair joining for agents requires use of the
        # new join service" -- an error that reads like a capability problem and
        # is actually the recovery mode. The working agents on this cluster
        # (agent-lgm, agent-siem) all have mode empty.
        limit = 10
      }
    }
  }
}

# ---- Container ---------------------------------------------------------------

resource "proxmox_virtual_environment_container" "db" {
  node_name   = var.proxmox_node
  vm_id       = var.vm_id
  tags        = ["teleport", "database", var.db_type, "terraform"]
  description = "Self-hosted ${var.db_type} for Teleport database access. Managed by terraform."

  # Unprivileged: unlike the k3s container this runs ordinary userspace daemons
  # and needs none of the mount/cgroup privileges kubelet does.
  unprivileged  = true
  started       = true
  start_on_boot = true

  operating_system {
    template_file_id = var.os_template_file_id
    type             = "ubuntu"
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size
  }

  initialization {
    hostname = local.name

    ip_config {
      ipv4 {
        address = "${var.container_ip}/${var.container_netmask}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }
}

# ---- Provisioning ------------------------------------------------------------
# Containers take no EC2-style user_data, so the engine and agent are installed
# by driving `pct exec` over one SSH hop to the node -- the same mechanism
# 1-cluster uses for k3s. The script is base64'd to survive two levels of shell
# quoting; assembling it inline does not.
#
# The script is moved in with `pct push`, NOT piped to `pct exec` on stdin:
# stdin forwarding through pct is unreliable, which is the same trap as
# `tctl -f /dev/stdin` against the distroless auth pod.

resource "null_resource" "provision" {
  depends_on = [proxmox_virtual_environment_container.db]

  triggers = {
    script = sha256(local.provision_script)
    vm_id  = var.vm_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      printf '%s' '${base64encode(local.provision_script)}' \
        | ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 '${var.proxmox_ssh}' \
            "set -e
             B=/tmp/provision-${local.name}
             cat > \$B.b64
             base64 -d \$B.b64 > \$B.sh
             # wait for the container's network before apt can work
             for i in \$(seq 1 30); do
               pct exec ${var.vm_id} -- getent hosts archive.ubuntu.com >/dev/null 2>&1 && break
               sleep 3
             done
             pct push ${var.vm_id} \$B.sh /tmp/provision.sh --perms 755
             pct exec ${var.vm_id} -- bash /tmp/provision.sh
             pct exec ${var.vm_id} -- rm -f /tmp/provision.sh
             rm -f \$B.b64 \$B.sh"
    EOT
  }
}

locals {
  provision_script = templatefile("${path.module}/provision-${var.db_type}.sh.tpl", {
    name             = local.name
    db_hostname      = var.db_hostname
    proxy_address    = var.proxy_address
    ca               = tls_self_signed_cert.ca_cert.cert_pem
    cert             = tls_locally_signed_cert.server_cert.cert_pem
    key              = tls_private_key.server_key.private_key_pem
    tele_ca          = var.teleport_db_ca
    env              = var.env
    engine           = var.db_type
    team             = var.team
    token            = teleport_provision_token.db.metadata.name
    registration_key = random_password.registration_secret.result
  })
}
