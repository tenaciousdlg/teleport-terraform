terraform {
  # State in the estate's R2 bucket (cloudflare-infra/r2-tfstate.tf), under
  # env:/<workspace>/<key> for the heronwright workspace. The account endpoint
  # and the key live in the `r2-tfstate` AWS profile, so nothing
  # account-specific is in this public repo.
  backend "s3" {
    bucket                      = "tfstate"
    key                         = "teleport-terraform/control-plane/proxmox/3-rbac/terraform.tfstate"
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
