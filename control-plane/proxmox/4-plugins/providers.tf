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
