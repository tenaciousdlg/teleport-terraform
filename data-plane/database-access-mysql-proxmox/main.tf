##################################################################################
# DATABASE ACCESS -- SELF-HOSTED MYSQL ON PROXMOX
##################################################################################
#
# The Proxmox twin of database-access-mysql-self-managed. Identical demo,
# no AWS: a self-hosted Postgres with TLS, fronted by a Teleport database agent
# that dials out to the proxy.
#
# PRE-FLIGHT, every time -- this layer uses the Teleport provider:
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv teleport
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

# Teleport's db-client CA. The engine adds it to ssl_ca_file so that the
# certificate the agent presents validates -- this is what makes cert auth work
# instead of passwords.
data "http" "teleport_db_ca_cert" {
  url = "https://${var.proxy_address}/webapi/auth/export?type=db-client"
}

module "mysql_instance" {
  source = "../../modules/self-database-lxc"

  db_type        = "mysql"
  db_hostname    = "mysql.${var.env}.internal"
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

# The database itself is a DYNAMIC resource, not a static entry in the agent's
# config. The agent matches it by label, so a second database later needs no
# change on the host.
module "mysql_registration" {
  source        = "../../modules/dynamic-registration"
  resource_type = "database"
  name          = "mysql-${var.env}"
  description   = "Self-hosted MariaDB for ${var.env} (Proxmox)"
  protocol      = "mysql"
  uri           = module.mysql_instance.db_uri
  ca_cert_chain = module.mysql_instance.ca_cert
  labels = {
    "env"  = var.env
    "team" = var.team
  }
}
