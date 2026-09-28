##################################################################################
# DATABASE ACCESS -- SELF-HOSTED POSTGRES ON PROXMOX
##################################################################################
#
# The Proxmox twin of database-access-postgres-self-managed. Identical demo,
# no AWS: a self-hosted Postgres with TLS, fronted by a Teleport database agent
# that dials out to the proxy.
#
# PRE-FLIGHT, every time -- this layer uses the Teleport provider:
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv heronwright
#
# Never `eval $(tctl terraform env)`: it mints an ephemeral bot, role and token
# per run, which is three admin actions and three MFA taps.

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
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# addr and credentials come from TF_TELEPORT_ADDR and
# TF_TELEPORT_IDENTITY_FILE_PATH, which tfenv exports. Nothing here holds a
# credential.
provider "teleport" {}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # The module provisions by driving `pct exec` over SSH, which the API token
  # alone cannot do. agent = true uses the caller's ssh-agent.
  ssh {
    agent = true
  }
}

# Teleport's db-client CA. The engine trusts it for CLIENT certs, which is the
# opposite direction from server auth and is what makes certificate auth work
# instead of passwords.
data "http" "teleport_db_ca_cert" {
  url = "https://${var.proxy_address}/webapi/auth/export?type=db-client"
}

module "mongodb_instance" {
  source = "../../modules/self-database-lxc"

  # MONGODB ON LXC, added 2026-09-28. The module's description previously said
  # "only postgres and mysql", but the reason it gave was specifically about
  # Cassandra being a JVM and the heaviest consumer on the hypervisor for the
  # engine demoed least. That argument does not extend to MongoDB, which is a
  # modest C++ daemon. Cassandra is still excluded, now by an explicit
  # validation rather than by prose.
  db_type        = "mongodb"
  db_hostname    = "mongodb.${var.env}.internal"
  env            = var.env
  team           = var.team
  proxy_address  = var.proxy_address
  teleport_db_ca = data.http.teleport_db_ca_cert.response_body

  proxmox_node        = var.proxmox_node
  proxmox_ssh         = "${var.proxmox_ssh_user}@${var.proxmox_ssh_host}"
  vm_id               = var.vm_id
  container_ip        = var.container_ip
  gateway             = var.gateway
  os_template_file_id = var.os_template_file_id
  datastore_id        = var.datastore_id
}

module "mongodb_registration" {
  source        = "../../modules/dynamic-registration"
  resource_type = "database"
  name          = "mongodb-${var.env}"
  description   = "Self-hosted MongoDB for ${var.env} (Proxmox)"
  protocol      = "mongodb"
  uri           = module.mongodb_instance.db_uri
  ca_cert_chain = module.mongodb_instance.ca_cert
  labels = {
    "env"    = var.env
    "team"   = var.team
    "engine" = "mongodb"
  }
}
