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
