terraform {
  required_version = ">= 1.6"

  # NO PROVIDERS. This layer is templatefile + null_resource, so it needs no
  # Teleport credential and no `tfenv` pre-flight to plan or apply.
  # The tokens these configs name are managed in
  # control-plane/proxmox/3-rbac/agents.tf, which does need one.

  backend "local" {
    path = "terraform.tfstate"
  }
}
