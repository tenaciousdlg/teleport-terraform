# Local backend — homelab, no S3. State lives next to the config and is read
# by the downstream layers via `terraform_remote_state` (local).
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
