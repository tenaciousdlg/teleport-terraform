##################################################################################
# TELEPORT HELM/SERVICE DEPLOYMENT
##################################################################################

resource "kubernetes_service_account" "teleport_auth" {
  metadata {
    name      = "teleport-cluster"
    namespace = kubernetes_namespace.teleport_cluster.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.teleport_auth.arn
    }
  }
}

resource "kubernetes_service_account" "teleport_proxy" {
  metadata {
    name      = "teleport-cluster-proxy"
    namespace = kubernetes_namespace.teleport_cluster.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.teleport_auth.arn
    }
  }
}

resource "kubernetes_service_account" "teleport_operator" {
  metadata {
    name      = "teleport-cluster-operator"
    namespace = kubernetes_namespace.teleport_cluster.metadata[0].name
  }
}

locals {
  # Conditional Access Graph config — populated when var.access_graph_enabled = true.
  # The ConfigMap teleport-access-graph-ca is created by 5-access-graph and mounted
  # at /var/run/access-graph so the auth service can verify the gRPC TLS certificate.
  access_graph_auth_config = var.access_graph_enabled ? {
    access_graph = {
      enabled  = true
      endpoint = "teleport-access-graph.teleport-access-graph.svc.cluster.local:443"
      ca       = "/var/run/access-graph/ca.pem"
      # Export the audit log to Access Graph for the Identity Activity Center.
      # NOTE: the Activity Center Dashboard also needs the IAC pipeline
      # (SQS/Athena/S3) enabled on the TAG side (5-access-graph); this flag
      # alone may not fully populate it.
      audit_log = {
        enabled = true
      }
    }
  } : {}

  # teleportConfig merges at the TOP level of the generated teleport.yaml, so
  # auth_service settings must be nested under an explicit auth_service key.
  # The chart (18.10.3) has no authentication.deviceTrust value — device_trust
  # only reaches the config through this raw merge.
  auth_teleport_config = merge(local.access_graph_auth_config, {
    auth_service = {
      authentication = {
        device_trust = { mode = "optional" }
      }
    }
  })

  access_graph_extra_volumes = var.access_graph_enabled ? [
    { name = "tag-ca", configMap = { name = "teleport-access-graph-ca" } }
  ] : []

  access_graph_extra_volume_mounts = var.access_graph_enabled ? [
    { name = "tag-ca", mountPath = "/var/run/access-graph" }
  ] : []
}

resource "helm_release" "teleport_cluster" {
  name       = "teleport-cluster"
  namespace  = kubernetes_namespace.teleport_cluster.metadata[0].name
  repository = "https://charts.releases.teleport.dev"
  chart      = "teleport-cluster"
  version    = var.teleport_version
  wait       = true
  # 300s produced a false "failed" release on 2026-07-09: the rolling
  # auth+proxy upgrade outlived the wait deadline after the manifests had
  # already applied. Rollouts legitimately take longer than 5 minutes.
  timeout = 600
  values = [
    jsonencode({
      clusterName       = var.proxy_address
      proxyListenerMode = "multiplex"
      acme              = false
      tls               = { existingSecretName = "teleport-tls" }
      enterprise        = fileexists("${path.module}/../../license.pem")
      labels            = { env = var.env, team = var.team }
      # webauthn-only (chart default would also allow otp); device_trust is set
      # via auth.teleportConfig below — the chart has no deviceTrust value.
      authentication = { type = "saml", secondFactors = ["webauthn"] }
      serviceAccount = { create = false, name = "teleport-cluster" }
      auth           = { serviceAccount = { create = false, name = "teleport-cluster" }, teleportConfig = local.auth_teleport_config }
      proxy          = { serviceAccount = { create = false, name = "teleport-cluster-proxy" } }
      operator       = { enabled = true, serviceAccount = { create = false, name = "teleport-cluster-operator" } }
      chartMode      = "aws"
      aws = {
        region                 = var.region
        backendTable           = aws_dynamodb_table.teleport_backend.name
        auditLogTable          = aws_dynamodb_table.teleport_events.name
        auditLogMirrorOnStdout = false
        dynamoAutoScaling      = false
        sessionRecordingBucket = aws_s3_bucket.session_recordings.bucket
      }
      extraVolumes      = local.access_graph_extra_volumes
      extraVolumeMounts = local.access_graph_extra_volume_mounts
    })
  ]
  depends_on = [
    kubectl_manifest.teleport_certificate,
    kubernetes_secret.license,
    kubernetes_service_account.teleport_auth,
    kubernetes_service_account.teleport_proxy,
    kubernetes_service_account.teleport_operator,
    aws_iam_role_policy_attachment.teleport_auth,
    aws_dynamodb_table.teleport_backend,
    aws_dynamodb_table.teleport_events,
    aws_s3_bucket.session_recordings
  ]
}

resource "time_sleep" "wait_for_operator" {
  depends_on      = [helm_release.teleport_cluster]
  create_duration = "60s"
}
