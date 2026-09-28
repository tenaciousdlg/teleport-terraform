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
# METRICS EXPOSURE (NodePort) — added 2026-09-27
##################################################################################
#
# Teleport's diagnostic listener is enabled in teleport.tf (diag_addr on both
# auth and proxy). This makes it reachable from OUTSIDE the cluster, because
# the collector is Alloy on CT104 and k3s pod IPs are not routable there.
#
# NodePort rather than LoadBalancer: klipper would hand a LoadBalancer the
# container's own IP, which is the same address, and a second LoadBalancer on
# this single-node cluster competes with the Teleport proxy's. A NodePort is
# the smaller thing that does the job.
#
# THESE PORTS ARE UNAUTHENTICATED AND ARE **NOT** FIREWALLED YET.
# Stating that plainly because an earlier draft of this comment claimed an
# nftables restriction that does not exist, which is the same
# comment-disagrees-with-config defect found in the Grafana JWT drop-in.
#
# What is true today: /metrics carries no credentials but does leak cluster
# shape and activity. Reachable from the Internal VLAN only — the Cloudflare
# tunnel forwards 443 and nothing else, and IoT is on VLAN 30 behind zone
# policies, so this is not internet-exposed. That is why it was judged
# acceptable to land tonight.
#
# What is NOT done: the restriction itself. Loki's precedent is nftables INSIDE
# the container (`tcp dport 3100 ip saddr <collector> accept; drop`), but this
# container runs k3s, which owns its own netfilter chains, so the same move
# here is control-plane surgery rather than a two-line rule. Tracked as work in
# open-items rather than pretended away here. The Proxmox per-container
# firewall is the likelier tool, since it applies at the bridge and does not
# touch k3s's tables.
resource "kubernetes_service" "auth_diag" {
  metadata {
    name      = "teleport-auth-diag"
    namespace = "teleport-cluster"
    labels    = { "app.kubernetes.io/name" = "teleport-diag" }
  }
  spec {
    type     = "NodePort"
    selector = { "app.kubernetes.io/component" = "auth", "app.kubernetes.io/name" = "teleport-cluster" }
    port {
      name        = "diag"
      port        = 3000
      target_port = 3000
      node_port   = 30300
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
    type     = "NodePort"
    selector = { "app.kubernetes.io/component" = "proxy", "app.kubernetes.io/name" = "teleport-cluster" }
    port {
      name        = "diag"
      port        = 3000
      target_port = 3000
      node_port   = 30301
      protocol    = "TCP"
    }
  }
  depends_on = [helm_release.teleport_cluster]
}
