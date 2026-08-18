# 6-cost — off-hours cost automation for presales
#
# EventBridge Scheduler flexes the cheap-to-bounce compute on a work-hours
# schedule using DIRECT SDK targets (no Lambda):
#   - spot nodegroup:  desired 2 -> 0 nightly, restored weekday mornings
#   - console host EC2: stopped nightly, started weekday mornings
# Weekends stay down (the "up" schedules are MON-FRI only).
#
# DELIBERATELY EXCLUDED (phase 2 candidates):
#   - stable nodegroup: hosts the event-handler PVC; scaling it 0->1 across
#     3 subnets risks AZ-stranding the volume (bit us 2026-08-14). Pin the
#     group to the PVC's AZ first, then it can join the schedule (~$19/mo).
#   - TAG RDS stop/start (~$5/mo), full teardown (the real lever, ~$190/mo:
#     EKS fee + NAT only die with destroy — see RESTORE-NOTES.md).
#
# Overnight state: pods from spot nodes go Pending or cram onto the stable
# node; Teleport may be degraded off-hours BY DESIGN. Everything rejoins on
# scale-up (event-handler token is in_cluster join as of 2026-08-17 — no
# JWKS rot on rejoin). Manual overrides:
#   aws eks update-nodegroup-config --cluster-name presales-cluster \
#     --nodegroup-name <spot-ng> --scaling-config minSize=1,maxSize=4,desiredSize=2
#   aws ec2 start-instances --instance-ids i-03c2dc6097c2079ad

terraform {
  backend "s3" {
    bucket       = "presales-teleport-demo-tfstate"
    key          = "control-plane/eks/6-cost/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.99"
    }
  }
}

provider "aws" {
  region = local.region
}

locals {
  region       = "us-east-2"
  cluster_name = "presales-cluster"
  # Re-derive after nodegroup recreation: aws eks list-nodegroups --cluster-name presales-cluster
  spot_nodegroup   = "presales-group-spot-20260710183718020200000008"
  console_host_id  = "i-03c2dc6097c2079ad" # dlg-prod-aws-console-host
  schedule_tz      = "America/Chicago"
  down_cron        = "cron(0 20 * * ? *)"      # daily 20:00
  up_cron          = "cron(45 7 ? * MON-FRI *)" # weekday mornings
}

data "aws_caller_identity" "current" {}

resource "aws_scheduler_schedule_group" "cost" {
  name = "presales-cost"
}

resource "aws_iam_role" "scheduler" {
  name = "presales-cost-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "presales-cost-scheduler"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:UpdateNodegroupConfig", "eks:DescribeNodegroup"]
        Resource = "arn:aws:eks:${local.region}:${data.aws_caller_identity.current.account_id}:nodegroup/${local.cluster_name}/${local.spot_nodegroup}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "ec2:StartInstances"]
        Resource = "arn:aws:ec2:${local.region}:${data.aws_caller_identity.current.account_id}:instance/${local.console_host_id}"
      }
    ]
  })
}

resource "aws_scheduler_schedule" "spot_down" {
  name                         = "presales-spot-down"
  group_name                   = aws_scheduler_schedule_group.cost.name
  schedule_expression          = local.down_cron
  schedule_expression_timezone = local.schedule_tz
  flexible_time_window { mode = "OFF" }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig"
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      ClusterName   = local.cluster_name
      NodegroupName = local.spot_nodegroup
      ScalingConfig = { MinSize = 0, MaxSize = 4, DesiredSize = 0 }
    })
  }
}

resource "aws_scheduler_schedule" "spot_up" {
  name                         = "presales-spot-up"
  group_name                   = aws_scheduler_schedule_group.cost.name
  schedule_expression          = local.up_cron
  schedule_expression_timezone = local.schedule_tz
  flexible_time_window { mode = "OFF" }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig"
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      ClusterName   = local.cluster_name
      NodegroupName = local.spot_nodegroup
      ScalingConfig = { MinSize = 1, MaxSize = 4, DesiredSize = 2 }
    })
  }
}

resource "aws_scheduler_schedule" "console_down" {
  name                         = "presales-consolehost-stop"
  group_name                   = aws_scheduler_schedule_group.cost.name
  schedule_expression          = local.down_cron
  schedule_expression_timezone = local.schedule_tz
  flexible_time_window { mode = "OFF" }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [local.console_host_id] })
  }
}

resource "aws_scheduler_schedule" "console_up" {
  name                         = "presales-consolehost-start"
  group_name                   = aws_scheduler_schedule_group.cost.name
  schedule_expression          = local.up_cron
  schedule_expression_timezone = local.schedule_tz
  flexible_time_window { mode = "OFF" }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [local.console_host_id] })
  }
}
