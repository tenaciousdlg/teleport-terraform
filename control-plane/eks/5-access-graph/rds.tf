##################################################################################
# RDS POSTGRESQL — Access Graph database
#
# Standard RDS instance, not Aurora: the AWS org's SCP explicitly denies
# rds:CreateDBCluster in this account (verified 2026-07-09), while
# rds:CreateDBInstance is allowed (the rds-mysql demos use it).
##################################################################################

# Subnet group using the EKS private subnets
resource "aws_db_subnet_group" "access_graph" {
  name        = "teleport-access-graph-${var.env}"
  subnet_ids  = data.terraform_remote_state.eks.outputs.private_subnets
  description = "Subnet group for Teleport Access Graph PostgreSQL"

  tags = {
    env  = var.env
    team = var.team
  }
}

# Security group: allow PostgreSQL only from within the VPC
resource "aws_security_group" "access_graph_db" {
  name        = "teleport-access-graph-db-${var.env}"
  description = "Allow PostgreSQL from EKS worker nodes"
  vpc_id      = data.terraform_remote_state.eks.outputs.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "PostgreSQL from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    env  = var.env
    team = var.team
  }
}

resource "aws_db_instance" "access_graph" {
  identifier             = "teleport-access-graph-${var.env}"
  engine                 = "postgres"
  engine_version         = "16.14"
  instance_class         = "db.t4g.small"
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = "access_graph"
  username               = "access_graph"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.access_graph.name
  vpc_security_group_ids = [aws_security_group.access_graph_db.id]
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = {
    env  = var.env
    team = var.team
  }
}
