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
      # externalTrafficPolicy Local preserves real client IPs. The default
      # (Cluster) SNATs NLB traffic to node IPs, which breaks Device Trust web
      # sessions: the device web token binds the client IP seen at login, and
      # the Connect authorize call arriving via a different node fails with
      # "invalid device web token" (IP mismatch, root-caused 2026-08-15).
      # Applied live via kubectl patch 2026-08-17; this keeps rebuilds correct.
      service = { spec = { externalTrafficPolicy = "Local" } }
      # Both proxy replicas co-schedule onto one node during the nightly
      # scale-down and stay stacked when the morning nodes return, leaving 1/3
      # NLB frontends healthy under externalTrafficPolicy=Local — clients that
      # draw a dead frontend from DNS hang (root-caused 2026-08-31 by
      # demo-sentinel's first full run; tbot renewal was the first casualty).
      # The chart's default SOFT spread constraints ARE on the deployment but
      # lose to resource scoring every morning: the emptiest node is always
      # the newest node, so both pods chase it (observed twice on 2026-08-31,
      # including a fresh rollout with all 3 nodes up). Hard DoNotSchedule
      # spread fixes it declaratively and self-heals the nightly cycle: the
      # second replica sits Pending overnight (cluster is asleep anyway) and
      # schedules the moment the morning node exists. matchLabelKeys scopes
      # this shared value per-component+ReplicaSet, so auth@1 is unaffected
      # (skew on a 1-replica set is trivially satisfied) and rollout surges
      # don't false-violate against the outgoing ReplicaSet.
      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "kubernetes.io/hostname"
        whenUnsatisfiable = "DoNotSchedule"
        labelSelector     = { matchLabels = { "app.kubernetes.io/name" = "teleport-cluster", "app.kubernetes.io/instance" = "teleport-cluster" } }
        matchLabelKeys    = ["app.kubernetes.io/component", "pod-template-hash"]
      }]
      serviceAccount = { create = false, name = "teleport-cluster" }
      auth           = { serviceAccount = { create = false, name = "teleport-cluster" }, teleportConfig = local.auth_teleport_config }
      # 3 replicas = one proxy per AZ node, so every NLB frontend serves a
      # LOCAL target. Mechanism (found 2026-08-31 via sentinel flaps): with
      # client-IP preservation + cross-zone both on, flows from one client
      # via multiple frontend IPs can collide in the target's conntrack and
      # drop SYNs (documented NLB behavior). Morning worst case: both
      # replicas on one node -> all 3 frontends cross-zoned into 1 target ->
      # sustained "dead frontend" symptoms. Local-target-per-AZ makes
      # cross-zone failover-only and the collisions disappear. Resource
      # requests/limits keep 3 proxies polite tenants on small nodes.
      proxy = {
        serviceAccount   = { create = false, name = "teleport-cluster-proxy" }
        highAvailability = { replicaCount = 3 }
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "1", memory = "1Gi" }
        }
      }
      operator  = { enabled = true, serviceAccount = { create = false, name = "teleport-cluster-operator" } }
      chartMode = "aws"
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
