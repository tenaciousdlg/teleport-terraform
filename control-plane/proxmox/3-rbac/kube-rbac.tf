# Kubernetes-side RBAC backing the scoped Teleport kube groups (roles.tf).
#
# system:masters bypasses ALL k8s RBAC — replaced with namespace-bound
# groups so both enforcement layers are real: Teleport's
# kubernetes_resources pins the namespace, and k8s RBAC scopes the verbs.
# The dev/prod namespaces (and their demo workloads) live in demo-apps.tf.

resource "kubernetes_role_binding_v1" "dev_editors" {
  metadata {
    name      = "teleport-dev-editors"
    namespace = kubernetes_namespace.dev.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "edit"
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "teleport-dev-editors"
  }
}

resource "kubernetes_role_binding_v1" "prod_editors" {
  metadata {
    name      = "teleport-prod-editors"
    namespace = kubernetes_namespace.prod.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "edit"
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "teleport-prod-editors"
  }
}

resource "kubernetes_role_binding_v1" "prod_viewers" {
  metadata {
    name      = "teleport-prod-viewers"
    namespace = kubernetes_namespace.prod.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "teleport-prod-viewers"
  }
}
