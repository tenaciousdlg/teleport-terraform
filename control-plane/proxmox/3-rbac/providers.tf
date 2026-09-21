##################################################################################
# PROVIDERS & REMOTE STATE
##################################################################################
# Adapted from eks/3-rbac/providers.tf: k3s admin client-cert auth from the
# LOCAL 1-cluster state, no aws / no exec plugin.

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "~> 18.0" # major must be a static string; bump on cluster upgrade
    }
  }
}

data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "../1-cluster/terraform.tfstate"
  }
}

locals {
  kube_host = data.terraform_remote_state.cluster.outputs.kube_host
  kube_ca   = base64decode(data.terraform_remote_state.cluster.outputs.cluster_ca_certificate)
  kube_cert = base64decode(data.terraform_remote_state.cluster.outputs.client_certificate)
  kube_key  = base64decode(data.terraform_remote_state.cluster.outputs.client_key)
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  client_certificate     = local.kube_cert
  client_key             = local.kube_key
}

provider "kubectl" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  client_certificate     = local.kube_cert
  client_key             = local.kube_key
  load_config_file       = false
}

# Teleport-native resources are moving off operator CRs and onto this provider
# (see ~/github/CLAUDE.md, "Terraform is the destination"). The operator keeps
# only bootstrap resources.
#
# Credentials come from tbot, NOT from `tctl terraform env` -- that mints an
# ephemeral bot + role + token on every run, which is three admin actions and
# three MFA taps. Pre-flight, every time, before plan or apply:
#
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv teleport
#
# which re-certs the persistent `terraform-local` bot over its bound keypair
# and exports TF_TELEPORT_ADDR + TF_TELEPORT_IDENTITY_FILE_PATH. The provider
# reads both from the environment, so this block stays empty and the layer
# carries no credential.
provider "teleport" {}

data "kubernetes_namespace" "teleport_cluster" {
  metadata {
    name = var.teleport_namespace
  }
}
