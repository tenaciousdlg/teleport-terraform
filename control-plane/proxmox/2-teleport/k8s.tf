##################################################################################
# CORE KUBERNETES RESOURCES
##################################################################################
# Kept verbatim from eks/2-teleport/k8s.tf. The license path is unchanged:
# proxmox/2-teleport is the same depth under control-plane as eks/2-teleport, so
# ${path.module}/../../license.pem still resolves to control-plane/license.pem.

resource "kubernetes_namespace" "teleport_cluster" {
  metadata {
    name = "teleport-cluster"
    annotations = {
      "kubectl.kubernetes.io/last-applied-configuration" = ""
    }
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

resource "kubernetes_secret" "license" {
  count = fileexists("${path.module}/../../license.pem") ? 1 : 0

  metadata {
    name      = "license"
    namespace = kubernetes_namespace.teleport_cluster.metadata[0].name
  }
  data = {
    "license.pem" = file("${path.module}/../../license.pem")
  }
  type = "Opaque"
}

##################################################################################
# METRICS ACCESS (via the API service proxy) — reworked 2026-09-28
##################################################################################
#
# WAS TWO NodePorts (30300/30301) SERVING /metrics UNAUTHENTICATED ON THE LAN.
# That was landed knowingly incomplete on 2026-09-27 with a comment saying so,
# and the plan was to firewall it. That plan is abandoned in favour of removing
# the port, for a reason worth recording:
#
# **Firewalling this container means enabling the PROXMOX CLUSTER firewall**,
# which also governs the hypervisor's own input policy. Getting that wrong locks
# you out of hollowtree, and this container had already crash-looped once that
# week. Fencing an unauthenticated port by touching the control plane's
# netfilter is a worse trade than not having the port.
#
# So the collector now reaches metrics through the KUBERNETES API SERVICE PROXY,
# which is already TLS-terminated and RBAC-gated on 6443:
#
#   /api/v1/namespaces/teleport-cluster/services/<svc>:diag/proxy/metrics
#
# Verified by hand before this was written: auth returns its metric families and
# proxy returns 232 matching lines through that path. Nothing is exposed to the
# LAN, the credential is a scoped ServiceAccount token, and no firewall rule is
# needed anywhere.
resource "kubernetes_service" "auth_diag" {
  metadata {
    name      = "teleport-auth-diag"
    namespace = "teleport-cluster"
    labels    = { "app.kubernetes.io/name" = "teleport-diag" }
  }
  spec {
    # ClusterIP, NOT NodePort. Reached only through the API proxy.
    type     = "ClusterIP"
    selector = { "app.kubernetes.io/component" = "auth", "app.kubernetes.io/name" = "teleport-cluster" }
    port {
      name        = "diag"
      port        = 3000
      target_port = 3000
      protocol    = "TCP"
    }
  }
  depends_on = [helm_release.teleport_cluster]
}

resource "kubernetes_service" "proxy_diag" {
  metadata {
    name      = "teleport-proxy-diag"
    namespace = "teleport-cluster"
    labels    = { "app.kubernetes.io/name" = "teleport-diag" }
  }
  spec {
    type     = "ClusterIP"
    selector = { "app.kubernetes.io/component" = "proxy", "app.kubernetes.io/name" = "teleport-cluster" }
    port {
      name        = "diag"
      port        = 3000
      target_port = 3000
      protocol    = "TCP"
    }
  }
  depends_on = [helm_release.teleport_cluster]
}

# ---- The scraper's identity ---------------------------------------------------
#
# Least privilege, and narrow enough to be worth reading: `get` on
# `services/proxy` for EXACTLY these two service names, in one namespace. It
# cannot list services, cannot read secrets, cannot reach any other service's
# proxy. A Role rather than a ClusterRole for the same reason.
resource "kubernetes_service_account" "metrics_scraper" {
  metadata {
    name      = "metrics-scraper"
    namespace = "teleport-cluster"
  }
}

resource "kubernetes_role" "metrics_scraper" {
  metadata {
    name      = "metrics-scraper"
    namespace = "teleport-cluster"
  }
  rule {
    api_groups     = [""]
    resources      = ["services/proxy"]
    resource_names = ["teleport-auth-diag:diag", "teleport-proxy-diag:diag"]
    verbs          = ["get"]
  }

  # ADDED 2026-09-28, for the bound_keypair recovery-headroom exporter.
  #
  # WHY THE KUBERNETES API AND NOT TELEPORT'S. `recovery_count` is runtime
  # STATUS, not config: it lives at `.status.bound_keypair.recovery_count` on
  # the operator CR, and Teleport exposes NO metric for it. That is exactly why
  # reading "3 of 30" required a hand query. The CRs are the operator's own
  # record of the same tokens, already reachable through the API this
  # ServiceAccount is set up for, so no second credential and no Teleport role
  # are needed.
  #
  # READ-ONLY, AND NOTHING SENSITIVE IS EXPOSED BY IT. A provision token CR
  # carries the token name, its roles, the recovery mode/limit/count and
  # `initial_public_key` — a PUBLIC key, which is the whole reason this estate
  # pre-registers keys instead of using registration secrets. There is no
  # secret in a bound_keypair token to leak. `list` is required as well as
  # `get` because the exporter enumerates every token rather than being told
  # their names, so a new agent appears in the panel without a config change.
  rule {
    api_groups = ["resources.teleport.dev"]
    resources  = ["teleportprovisiontokens"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "metrics_scraper" {
  metadata {
    name      = "metrics-scraper"
    namespace = "teleport-cluster"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.metrics_scraper.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.metrics_scraper.metadata[0].name
    namespace = "teleport-cluster"
  }
}

# A LONG-LIVED token, deliberately. Since Kubernetes 1.24 a ServiceAccount no
# longer gets one automatically, and the projected-token alternative requires
# the consumer to run INSIDE the cluster. The collector is on another host, so
# an explicit Secret is the supported way to give an outside scraper an
# identity.
#
# The token is NOT read into terraform state here. homelab/siem fetches it at
# delivery time and writes it straight onto the collector, so it exists in the
# cluster and on that one host and nowhere else.
resource "kubernetes_secret" "metrics_scraper_token" {
  metadata {
    name      = "metrics-scraper-token"
    namespace = "teleport-cluster"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.metrics_scraper.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}
