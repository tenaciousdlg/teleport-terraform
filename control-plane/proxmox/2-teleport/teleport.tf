##################################################################################
# TELEPORT HELM DEPLOYMENT (standalone / k3s)
##################################################################################
#
# Adapted from eks/2-teleport/teleport.tf. Changes vs. the EKS version:
#   - chartMode "aws" -> "standalone"; the entire aws{} block (DynamoDB + S3) is
#     gone. Standalone keeps the auth backend + session recordings on a PVC.
#   - persistence enabled on k3s's default StorageClass (local-path).
#   - service.spec.externalTrafficPolicy removed (no NLB; klipper servicelb
#     fronts the Service and hands it the VM IP directly).
#   - topologySpreadConstraints removed (single node — nothing to spread).
#   - proxy.highAvailability.replicaCount 3 -> 1 (single node).
#   - IRSA service accounts removed: the chart creates its own SAs (no
#     eks.amazonaws.com/role-arn annotations, no aws_iam_role in this layer).
#
# Kept from EKS: clusterName, proxyListenerMode=multiplex, acme=false,
# existingSecretName TLS, enterprise-from-license, env/team labels,
# saml + webauthn authentication, device_trust=optional via auth.teleportConfig,
# operator enabled, the access_graph conditional (off here).

locals {
  # Conditional Access Graph config — populated when var.access_graph_enabled =
  # true. Off for the Proxmox replica (5-access-graph is out of scope), but kept
  # so this block stays identical to eks/2-teleport for easy diffing.
  access_graph_auth_config = var.access_graph_enabled ? {
    access_graph = {
      enabled  = true
      endpoint = "teleport-access-graph.teleport-access-graph.svc.cluster.local:443"
      ca       = "/var/run/access-graph/ca.pem"
      # audit_log export requires the Identity Activity Center, a SEPARATE
      # component that is not deployed here. With it on but IAC absent, auth
      # logs "Identity activity center is not configured, cannot process
      # Teleport Audit Log stream" in a loop while the graph itself works fine.
      audit_log = {
        enabled = var.access_graph_audit_log_enabled
      }
    }
  } : {}

  # teleportConfig merges at the TOP level of the generated teleport.yaml, so
  # auth_service settings must be nested under an explicit auth_service key.
  # device_trust only reaches the config through this raw merge (the chart has
  # no authentication.deviceTrust value).
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
  # Rollouts legitimately take longer than 5 minutes (see eks history); 600s.
  timeout = 600
  values = [
    jsonencode({
      clusterName       = var.proxy_address
      proxyListenerMode = "multiplex"
      acme              = false
      tls               = { existingSecretName = "teleport-tls" }
      enterprise        = fileexists("${path.module}/../../license.pem")
      labels            = { env = var.env, team = var.team }
      # Auth type/second-factors are variables (Phase 1 = local+otp/webauthn;
      # Phase 2 flips type→saml and tightens to webauthn-only to match presales).
      # device_trust is set via auth.teleportConfig below — the chart has no
      # deviceTrust value.
      # connectorName is set explicitly rather than left to Teleport's pick, so
      # adding a second SSO connector later cannot silently change which one
      # the login page offers. local auth stays enabled underneath (the
      # cluster_auth_preference keeps allow_local_auth: true), so the local
      # admin remains a break-glass path if Okta is unavailable.
      authentication = merge(
        { type = var.authentication_type, secondFactors = var.second_factors },
        var.authentication_connector_name != "" ? { connectorName = var.authentication_connector_name } : {},
      )

      # Standalone chart mode: auth backend on-disk instead of DynamoDB, session
      # recordings on-disk instead of S3. The PVC uses k3s's built-in local-path
      # provisioner (the default StorageClass on a fresh k3s install).
      chartMode = "standalone"
      persistence = {
        enabled          = true
        storageClassName = "local-path"
      }

      # Chart creates its own service accounts — no IRSA annotations needed
      # without AWS. Names pinned so they stay stable across upgrades.
      serviceAccount = { create = true, name = "teleport-cluster" }
      auth = {
        serviceAccount = { create = true, name = "teleport-cluster" }
        teleportConfig = local.auth_teleport_config
      }
      # Single node: one proxy replica. Resource requests/limits kept so the
      # proxy stays a polite tenant on the 8GB VM.
      proxy = {
        serviceAccount   = { create = true, name = "teleport-cluster-proxy" }
        highAvailability = { replicaCount = 1 }
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "1", memory = "1Gi" }
        }
        # The proxy serves the web UI and reaches Access Graph ITSELF, so it
        # needs the same endpoint + CA as auth. The docs' Helm example only
        # shows auth.teleportConfig; without this the proxy logs "access graph
        # service is not reachable, returning 404" and Identity Security
        # renders empty while auth is happily importing.
        teleportConfig = local.access_graph_auth_config
      }
      operator = { enabled = true, serviceAccount = { create = true, name = "teleport-cluster-operator" } }

      extraVolumes      = local.access_graph_extra_volumes
      extraVolumeMounts = local.access_graph_extra_volume_mounts
    })
  ]
  depends_on = [
    kubectl_manifest.teleport_certificate,
    kubernetes_secret.license,
  ]
}

resource "time_sleep" "wait_for_operator" {
  depends_on      = [helm_release.teleport_cluster]
  create_duration = "60s"
}
