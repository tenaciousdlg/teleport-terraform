# Profile: cloud-cli — Azure + GCP CLI access through Teleport App Access.
#
# Independent lifecycle by design: `terraform apply` / `terraform destroy`
# here spins the cloud agents up and down without touching any other
# profile. Both agents use native cloud join methods (azure/gcp) —
# tokenless, no TTL, replacement-safe.
#
# Role wiring lives in control-plane/eks/3-rbac (prod-readonly-access
# carries azure_identities + gcp_service_accounts), so elevation via the
# standard JIT flow reveals and unlocks both apps.
#
# Auth: azurerm uses your `az login` session; google uses ADC
# (`gcloud auth application-default login`); teleport via tfenv.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "~> 18.0"
    }
  }
}

provider "teleport" {
  addr = "${var.proxy_address}:443"
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}

provider "google" {
  project = var.gcp_project_id
}

module "azure_cli" {
  count  = var.enable_azure ? 1 : 0
  source = "../../modules/cloud-azure-cli"

  subscription_id = var.azure_subscription_id
  proxy_address   = var.proxy_address
  env             = var.env
  team            = var.team
}

module "gcp_cli" {
  count  = var.enable_gcp ? 1 : 0
  source = "../../modules/cloud-gcp-cli"

  project_id    = var.gcp_project_id
  proxy_address = var.proxy_address
  env           = var.env
  team          = var.team
}

output "azure_identity" {
  value = var.enable_azure ? module.azure_cli[0].identity_resource_id : null
}

output "gcp_viewer_service_account" {
  value = var.enable_gcp ? module.gcp_cli[0].viewer_service_account : null
}
