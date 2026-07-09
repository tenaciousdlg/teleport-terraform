terraform {
  backend "s3" {
    bucket       = "presales-teleport-demo-tfstate"
    key          = "control-plane/eks/1-cluster/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
  }
}
