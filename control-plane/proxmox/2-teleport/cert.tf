##################################################################################
# CERT-MANAGER INSTALLATION & CLUSTER ISSUER (self-signed)
##################################################################################
#
# Adapted from eks/2-teleport/cert-manager.tf. Changes:
#   - dropped the Route53/IAM (IRSA) wiring — no aws_iam_role_policy_attachment
#     dependency, no serviceAccount.annotations dynamic set.
#   - REMOVED the letsencrypt-prod ACME/Route53 ClusterIssuer entirely.
#   - teleport-tls Certificate now issued by the selfsigned-issuer.
#
# Why self-signed at the origin: Cloudflare's edge presents the real public cert
# for teleport.chrisdlg.com. The k3s origin sits behind the cloudflared tunnel,
# which dials it with no_tls_verify=true (see cloudflare-infra/hollowtree-tunnel.tf),
# so the origin only needs *a* cert on :443 — a self-signed one is sufficient.

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.16.2"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "crds.enabled"
    value = "true"
  }
  set {
    name  = "global.leaderElection.namespace"
    value = "cert-manager"
  }
  set {
    name  = "prometheus.enabled"
    value = "true"
  }
}

resource "time_sleep" "wait_for_cert_manager" {
  depends_on      = [helm_release.cert_manager]
  create_duration = "90s"
}

resource "kubectl_manifest" "selfsigned_issuer" {
  depends_on = [time_sleep.wait_for_cert_manager]
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "selfsigned-issuer" }
    spec       = { selfSigned = {} }
  })
}

resource "time_sleep" "wait_for_issuer" {
  depends_on      = [kubectl_manifest.selfsigned_issuer]
  create_duration = "30s"
}

resource "kubectl_manifest" "teleport_certificate" {
  depends_on = [time_sleep.wait_for_issuer, kubernetes_namespace.teleport_cluster]
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "teleport-tls"
      namespace = kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      secretName  = "teleport-tls"
      issuerRef   = { name = "selfsigned-issuer", kind = "ClusterIssuer" }
      dnsNames    = [var.proxy_address, "*.${var.proxy_address}"]
      duration    = "2160h"
      renewBefore = "720h"
    }
  })
}
