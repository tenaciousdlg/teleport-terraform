##################################################################################
# PROVIDERS & REMOTE STATE
##################################################################################
#
# Copied from 2-teleport/providers.tf -- same k3s, same auth. Differences:
#   - no aws provider, no `aws eks get-token` exec auth
#   - remote state is the LOCAL 1-cluster state, not S3
#   - k8s/helm/kubectl auth with the k3s admin client cert/key + CA (not exec)

terraform {
  # State in the estate's R2 bucket (cloudflare-infra/r2-tfstate.tf), under
  # env:/<workspace>/<key> for the heronwright workspace. The account endpoint
  # and the key live in the `r2-tfstate` AWS profile, so nothing
  # account-specific is in this public repo.
  backend "s3" {
    bucket                      = "tfstate"
    key                         = "teleport-terraform/control-plane/proxmox/5-access-graph/terraform.tfstate"
    region                      = "auto"
    profile                     = "r2-tfstate"
    use_lockfile                = true
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Read k3s cluster info from the 1-cluster local state (NO MANUAL COORDINATION).
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

# Read the Teleport cluster NAME from 2-teleport, for the host-CA staleness
# check in main.tf. Nothing else here needs it; it exists so that pinning the
# wrong cluster's host CA fails at APPLY time rather than in the product UI.
data "terraform_remote_state" "teleport" {
  # 2-teleport's outputs, read from the estate's R2 bucket in the SAME workspace
  # as this layer (env:/<workspace>/<key>), so a second cluster built from
  # this code in its own workspace reads its own 2-teleport state. Read from
  # ../2-teleport/terraform.tfstate.d until the 2026-10-13 move to R2.
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket                      = "tfstate"
    key                         = "teleport-terraform/control-plane/proxmox/2-teleport/terraform.tfstate"
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

provider "helm" {
  kubernetes {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca
    client_certificate     = local.kube_cert
    client_key             = local.kube_key
  }
}

provider "kubectl" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  client_certificate     = local.kube_cert
  client_key             = local.kube_key
  load_config_file       = false
}
