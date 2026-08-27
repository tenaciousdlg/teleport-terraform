terraform {
  required_providers {
    teleport = {
      source = "terraform.releases.teleport.dev/gravitational/teleport"
    }
    aws = {
      source = "hashicorp/aws"
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

# iam join: a static allow-rule token — the instance proves itself with a
# signed sts:GetCallerIdentity under the shared join role. No secret, no
# TTL, replacement-safe (the 8h ephemeral token silently orphaned any
# instance replaced >8h after apply — see modules/iam-join).
resource "teleport_provision_token" "agent" {
  version = "v2"
  metadata = {
    name        = "iam-node-${random_string.token.result}"
    description = "iam join for ssh-node agents"
  }
  spec = {
    roles       = ["Node"]
    join_method = "iam"
    allow       = [{ aws_arn = var.join_arn_pattern }]
  }
}

resource "aws_instance" "ssh_node" {
  count                  = var.agent_count
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.instance_profile_name
  # Teleport nodes register via outbound reverse tunnel — no public IP needed.
  associate_public_ip_address = null

  user_data = templatefile("${path.module}/userdata.tpl", {
    token            = teleport_provision_token.agent.metadata.name
    proxy_address    = var.proxy_address
    teleport_version = var.teleport_version
    env              = var.env
    name             = "${var.env}-ssh-${count.index}"
    team             = var.team
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = 30 # required for AMZN Linux 2023 AMI EBS size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${local.user}-${var.env}-ssh-${count.index}"
  })
}
