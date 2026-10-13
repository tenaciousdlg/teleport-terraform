terraform {
  required_version = ">= 1.6"

  # NO PROVIDERS. This layer is templatefile + null_resource, so it needs no
  # Teleport credential and no `tfenv` pre-flight to plan or apply.
  # The tokens these configs name are managed in
  # control-plane/proxmox/3-rbac/agents.tf, which does need one.

  # State in the estate's R2 bucket (cloudflare-infra/r2-tfstate.tf). The
  # account endpoint and the key live in the `r2-tfstate` AWS profile, so
  # nothing account-specific is in this repo.
  backend "s3" {
    bucket                      = "tfstate"
    key                         = "teleport-terraform/data-plane/estate-agents/terraform.tfstate"
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
}
