terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    teleport = {
      source = "terraform.releases.teleport.dev/gravitational/teleport"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

locals {
  user = lower(split("@", var.user)[0])
}

resource "random_string" "token" {
  length  = 32
  special = false
}

# iam join: static allow-rule token — instance identity attested via signed
# sts:GetCallerIdentity. No secret, no TTL, replacement-safe (the 8h token +
# ignore_changes pattern orphaned replacement instances; see modules/iam-join).
resource "teleport_provision_token" "httpbin" {
  version = "v2"
  metadata = {
    name        = "iam-httpbin-${random_string.token.result}"
    description = "iam join (httpbin)"
  }
  spec = {
    roles       = ["App", "Node"]
    join_method = "iam"
    allow       = [{ aws_arn = var.join_arn_pattern }]
  }
}

resource "aws_instance" "httpbin" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.instance_profile_name
  # Teleport nodes register via outbound reverse tunnel — no public IP needed.
  associate_public_ip_address = null

  user_data = templatefile("${path.module}/userdata.tpl", {
    name             = "${var.env}-httpbin"
    token            = teleport_provision_token.httpbin.metadata.name
    proxy_address    = var.proxy_address
    teleport_version = var.teleport_version
    env              = var.env
    user             = local.user
    team             = var.team
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${local.user}-${var.env}-httpbin"
  })
}
