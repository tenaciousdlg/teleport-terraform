##################################################################################
# PROVIDERS & REMOTE STATE
##################################################################################
# Adapted from eks/4-plugins/providers.tf: k3s admin client-cert auth from the
# LOCAL 1-cluster state, no aws / no exec plugin.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

data "terraform_remote_state" "cluster" {
  # 1-cluster's outputs, read from the estate's R2 bucket in the SAME workspace
  # as this layer (env:/<workspace>/<key>), so a second cluster built from
  # this code in its own workspace reads its own 1-cluster state. Read from
  # ../1-cluster/terraform.tfstate.d until the 2026-10-13 move to R2.
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket                      = "tfstate"
    key                         = "teleport-terraform/control-plane/proxmox/1-cluster/terraform.tfstate"
    region                      = "auto"
    profile                     = "r2-tfstate"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
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

provider "helm" {
  kubernetes {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca
    client_certificate     = local.kube_cert
    client_key             = local.kube_key
  }
}

data "kubernetes_namespace" "teleport_cluster" {
  metadata {
    name = var.teleport_namespace
  }
}
