terraform {
  required_providers {
    teleport = {
      source = "terraform.releases.teleport.dev/gravitational/teleport"
    }
    aws = {
      source = "hashicorp/aws"
    }
    tls = {
      source = "hashicorp/tls"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

locals {
  user = lower(split("@", var.user)[0])
}

resource "tls_private_key" "ca_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca_cert" {
  private_key_pem = tls_private_key.ca_key.private_key_pem
  subject {
    common_name  = "example"
    organization = "example"
  }
  validity_period_hours = 87600 # 10 years
  is_ca_certificate     = true
  allowed_uses          = ["cert_signing", "client_auth", "server_auth", "key_encipherment", "digital_signature"]
}

resource "tls_private_key" "server_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server_csr" {
  private_key_pem = tls_private_key.server_key.private_key_pem
  subject {
    common_name  = var.db_hostname
    organization = "example"
  }
  dns_names = [var.db_hostname, "localhost", "127.0.0.1"]
}

resource "tls_locally_signed_cert" "server_cert" {
  cert_request_pem      = tls_cert_request.server_csr.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca_key.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours = 8760
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth", "client_auth"]
}

resource "random_string" "token" {
  length  = 32
  special = false
}

# iam join: static allow-rule token — instance identity attested via signed
# sts:GetCallerIdentity. No secret, no TTL, replacement-safe (the 8h token +
# ignore_changes pattern orphaned replacement instances; see modules/iam-join).
resource "teleport_provision_token" "db" {
  version = "v2"
  metadata = {
    name        = "iam-db-${random_string.token.result}"
    description = "iam join (db)"
  }
  spec = {
    roles       = ["Db", "Node"]
    join_method = "iam"
    allow       = [{ aws_arn = var.join_arn_pattern }]
  }
}

resource "aws_instance" "db" {
  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  # security_groups is the EC2-Classic/default-VPC (name-based) attribute; on
  # VPC instances it refreshes as [] and forces replacement on every plan.
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.instance_profile_name
  # Teleport nodes register via outbound reverse tunnel — no public IP needed.
  associate_public_ip_address = null

  user_data = templatefile("${path.module}/userdata-${var.db_type}.tpl", {
    name             = "${var.env}-${var.db_type}"
    token            = teleport_provision_token.db.metadata.name
    proxy_address    = var.proxy_address
    teleport_version = var.teleport_version
    ca               = tls_self_signed_cert.ca_cert.cert_pem
    cert             = tls_locally_signed_cert.server_cert.cert_pem
    key              = tls_private_key.server_key.private_key_pem
    tele_ca          = var.teleport_db_ca
    env              = var.env
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

  tags = {
    Name = "${local.user}-${var.env}-${var.db_type}"
  }
}
