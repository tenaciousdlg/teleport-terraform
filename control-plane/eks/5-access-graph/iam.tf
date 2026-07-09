##################################################################################
# IRSA — passwordless RDS access for TAG
#
# Lets the teleport-access-graph service account assume an IAM role that may
# `rds-db:connect` as the access_graph DB user, so TAG authenticates with a
# short-lived IAM token instead of a stored password. Scoped to this one SA
# and this one DB user — blast radius is TAG only.
##################################################################################

data "aws_caller_identity" "current" {}

locals {
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider_url = replace(local.oidc_provider_arn, "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/", "")
  tag_sa            = "system:serviceaccount:${kubernetes_namespace.access_graph.metadata[0].name}:teleport-access-graph"
}

resource "aws_iam_role" "access_graph_rds" {
  name = "teleport-access-graph-rds-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = local.tag_sa
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    env  = var.env
    team = var.team
  }
}

resource "aws_iam_role_policy" "access_graph_rds" {
  name = "rds-connect"
  role = aws_iam_role.access_graph_rds.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.access_graph.resource_id}/access_graph"
    }]
  })
}
