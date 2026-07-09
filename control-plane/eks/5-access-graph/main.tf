# control-plane/eks/5-access-graph/main.tf
#
# Deploys Teleport Access Graph (Identity Security) into the EKS cluster.
# Depends on: 1-cluster (remote state), 2-teleport (cluster running), 3-rbac (roles exist).
#
# What gets created:
#   AWS resources:
#     - RDS PostgreSQL 16 instance (db.t4g.small) — Access Graph database
#       (standard RDS, not Aurora — Aurora is SCP-denied in this account)
#     - DB subnet group + security group in the EKS VPC
#     - IRSA role (iam.tf) for passwordless RDS + Identity Activity Center access
#     - Identity Activity Center pipeline (iac.tf): KMS key, 2 SQS queues,
#       2 S3 buckets, Glue database + table, Athena workgroup (iac-policy.tf
#       attaches the access policy to the IRSA role)
#
#   Kubernetes resources:
#     - Namespace:   teleport-access-graph
#     - Secret:      teleport-access-graph-postgres  (password URI — unused; TAG uses IAM)
#     - Secret:      teleport-access-graph-tls       (gRPC TLS cert/key)
#     - ConfigMap:   teleport-access-graph-ca        (in teleport-cluster namespace)
#     - Helm release: teleport-access-graph (passwordless RDS + IAC enabled)
#
# After applying, re-apply 2-teleport with TF_VAR_access_graph_enabled=true
# (already the live value) — it also sets access_graph.audit_log.enabled=true,
# the auth-side half of the Identity Activity Center. Run the one-time
# rds_iam grant (see README) for passwordless auth. No other manual steps.

locals {
  chart_version = var.access_graph_chart_version != "" ? var.access_graph_chart_version : null
}

##################################################################################
# TLS CERTIFICATE (self-signed, scoped to internal Kubernetes service DNS)
##################################################################################

resource "tls_private_key" "access_graph" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "access_graph" {
  private_key_pem = tls_private_key.access_graph.private_key_pem

  subject {
    common_name  = "teleport-access-graph"
    organization = "Teleport Access Graph"
  }

  validity_period_hours = 8760 # 1 year

  dns_names = [
    "teleport-access-graph",
    "teleport-access-graph.teleport-access-graph",
    "teleport-access-graph.teleport-access-graph.svc",
    "teleport-access-graph.teleport-access-graph.svc.cluster.local",
  ]

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

##################################################################################
# KUBERNETES: namespace, secrets, ConfigMap
##################################################################################

resource "kubernetes_namespace" "access_graph" {
  metadata {
    name = "teleport-access-graph"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# PostgreSQL connection URI — read by the Access Graph Helm chart
resource "kubernetes_secret" "access_graph_postgres" {
  metadata {
    name      = "teleport-access-graph-postgres"
    namespace = kubernetes_namespace.access_graph.metadata[0].name
  }
  data = {
    uri = "postgres://access_graph:${var.db_password}@${aws_db_instance.access_graph.address}:5432/access_graph?sslmode=require"
  }
  type       = "Opaque"
  depends_on = [aws_db_instance.access_graph]
}

# TLS certificate for the Access Graph gRPC listener
resource "kubernetes_secret" "access_graph_tls" {
  metadata {
    name      = "teleport-access-graph-tls"
    namespace = kubernetes_namespace.access_graph.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_self_signed_cert.access_graph.cert_pem
    "tls.key" = tls_private_key.access_graph.private_key_pem
  }
}

# CA cert ConfigMap in the Teleport namespace — mounted by 2-teleport auth pods
# so the auth service can verify the Access Graph TLS certificate.
resource "kubernetes_config_map" "access_graph_ca" {
  metadata {
    name      = "teleport-access-graph-ca"
    namespace = var.teleport_namespace
  }
  data = {
    "ca.pem" = tls_self_signed_cert.access_graph.cert_pem
  }
}

##################################################################################
# HELM: teleport-access-graph
##################################################################################

resource "helm_release" "access_graph" {
  depends_on = [
    kubernetes_secret.access_graph_postgres,
    kubernetes_secret.access_graph_tls,
    aws_db_instance.access_graph,
    aws_iam_role_policy.access_graph_iac,
    aws_glue_catalog_table.identity_activity_center_table,
  ]

  name       = "teleport-access-graph"
  repository = "https://charts.releases.teleport.dev"
  chart      = "teleport-access-graph"
  namespace  = kubernetes_namespace.access_graph.metadata[0].name
  version    = local.chart_version
  wait       = true
  timeout    = 300

  values = [yamlencode({
    replicaCount = 1

    # Guarantee TAG enough memory that its initial graph import doesn't
    # self-starve when co-scheduled with the proxy on a t3.small node
    # (the "Launching Identity Security…" hang, 2026-07-09). The 512Mi
    # request fits the free headroom on the existing t3.small nodes, so
    # the scheduler places it without adding a node (no extra cost); the
    # 1Gi limit gives the import room to burst. No CPU limit — CPU limits
    # cause throttling; the request alone is enough for scheduling.
    resources = {
      requests = {
        cpu    = "250m"
        memory = "512Mi"
      }
      limits = {
        memory = "1Gi"
      }
    }

    # Passwordless: TAG assumes the IRSA role and authenticates to RDS with a
    # short-lived IAM token (no stored DB password). Requires the DB user to
    # hold the rds_iam role (granted out of band) and RDS IAM auth enabled.
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.access_graph_rds.arn
      }
    }

    postgres = {
      connectionString = "postgres://access_graph@${aws_db_instance.access_graph.address}:5432/access_graph?sslmode=require"
      aws = {
        enabled = true
        region  = var.region
      }
    }

    # Identity Activity Center — audit-log analytics pipeline (SQS -> S3 ->
    # Athena/Glue). Backs the "Dashboard" view. TAG reads/writes these via the
    # IRSA role (see iac-policy.tf). The auth side exports events via
    # access_graph.audit_log.enabled=true in 2-teleport.
    identity_activity_center = {
      enabled        = true
      region         = var.region
      database       = aws_glue_catalog_database.identity_activity_center_db.name
      table          = aws_glue_catalog_table.identity_activity_center_table.name
      workgroup      = aws_athena_workgroup.identity_activity_center_workgroup.name
      sqs_queue_url  = aws_sqs_queue.identity_activity_center_queue.url
      s3             = "s3://${aws_s3_bucket.identity_activity_center_long_term_storage.bucket}/data"
      s3_results     = "s3://${aws_s3_bucket.identity_activity_center_transient_storage.bucket}/results"
      s3_large_files = "s3://${aws_s3_bucket.identity_activity_center_transient_storage.bucket}/large_files"
    }

    tls = {
      existingSecretName = kubernetes_secret.access_graph_tls.metadata[0].name
    }

    # List of PEM-encoded Teleport host CA certs allowed to connect to this instance.
    # Retrieve with: curl 'https://<proxy>/webapi/auth/export?type=tls-host'
    clusterHostCAs = [var.teleport_host_ca]
  })]
}
