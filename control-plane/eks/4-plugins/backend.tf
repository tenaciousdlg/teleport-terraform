terraform {
  backend "s3" {
    bucket       = "presales-teleport-demo-tfstate"
    key          = "control-plane/eks/4-plugins/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
  }
}
