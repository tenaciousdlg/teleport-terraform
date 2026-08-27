# Shared IAM join identity for Teleport agents.
#
# One EC2 role + instance profile per deployment. Agents attach the profile
# and join with the native `iam` method: the auth service verifies a signed
# sts:GetCallerIdentity — no join secret, no token TTL. This retires the
# 8h-token + ignore_changes pattern that silently orphaned replacement
# instances (desktop-service, 2026-08-27): iam-method tokens are static
# allow-rules with nothing to expire.
#
# The role grants NO AWS permissions — it exists purely as an attested
# join identity.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.99"
    }
  }
}

variable "name" {
  description = "Deployment-unique name for the join role/profile (e.g. dev-demo)"
  type        = string
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "join" {
  name = "${var.name}-teleport-join"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "join" {
  name = "${var.name}-teleport-join"
  role = aws_iam_role.join.name
}

output "instance_profile_name" {
  description = "Attach to agent instances"
  value       = aws_iam_instance_profile.join.name
}

output "joined_arn_pattern" {
  description = "aws_arn allow-rule for iam-method provision tokens"
  value       = "arn:aws:sts::${data.aws_caller_identity.current.account_id}:assumed-role/${aws_iam_role.join.name}/*"
}

output "aws_account_id" {
  description = "Account for token allow rules"
  value       = data.aws_caller_identity.current.account_id
}
