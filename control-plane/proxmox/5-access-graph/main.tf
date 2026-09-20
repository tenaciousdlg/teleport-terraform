##################################################################################
# 5-ACCESS-GRAPH -- Teleport Identity Security (Access Graph)
##################################################################################
#
# Requires, and this cluster has: Teleport Enterprise 18.11.0 and a license with
# Identity Security. Verified in the auth log --
#   entitlements:<key:"Policy" value:<enabled:true> >   IdentityGovernance:true
#
# Access Graph is a separate service backed by PostgreSQL that talks to Auth and
# Proxy over mTLS. Everything here is ADDITIVE and lives in its own namespace;
# the one change to the running cluster is in 2-teleport, which points Teleport
# at this service and requires an auth/proxy restart.

locals {
  ag_namespace = "teleport-access-graph"
  ag_service   = "teleport-access-graph"
  # Service DNS must appear in the cert SAN, per the chart's requirements.
  ag_dns = "${local.ag_service}.${local.ag_namespace}.svc.cluster.local"

  pg_user = "accessgraph"
  pg_db   = "accessgraph"
}

resource "kubernetes_namespace" "ag" {
  metadata {
    name = local.ag_namespace
  }
}

# --- PostgreSQL ------------------------------------------------------------
# A plain StatefulSet rather than a third-party chart: one small database with
# no HA requirement, and one less upstream whose defaults can move underneath
# this. Access Graph needs to OWN its database (CREATE TABLE + CREATE SCHEMA),
# which a dedicated instance gives for free.

resource "random_password" "pg" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "pg" {
  metadata {
    name      = "teleport-access-graph-postgres"
    namespace = kubernetes_namespace.ag.metadata[0].name
  }
  data = {
    # The chart reads the whole connection string from this key.
    # sslmode=disable: the hop is pod-to-pod inside k3s on one host. Revisit if
    # Postgres ever moves off-cluster.
    uri      = "postgres://${local.pg_user}:${random_password.pg.result}@postgres:5432/${local.pg_db}?sslmode=disable"
    username = local.pg_user
    password = random_password.pg.result
    database = local.pg_db
  }
}

resource "kubernetes_stateful_set" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.ag.metadata[0].name
    labels    = { app = "postgres" }
  }
  spec {
    service_name = "postgres"
    replicas     = 1
    selector { match_labels = { app = "postgres" } }
    template {
      metadata { labels = { app = "postgres" } }
      spec {
        container {
          name = "postgres"
          # pgvector, not plain postgres: Access Graph's migrations ask for the
          # pgvector extension and log "extension not available" against a stock
          # image. Functional without it, but a degraded feature set for no
          # reason -- this image is postgres 16 with the extension present.
          image = "pgvector/pgvector:pg16"
          port { container_port = 5432 }
          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.pg.metadata[0].name
                key  = "username"
              }
            }
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.pg.metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name = "POSTGRES_DB"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.pg.metadata[0].name
                key  = "database"
              }
            }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          readiness_probe {
            exec { command = ["pg_isready", "-U", local.pg_user, "-d", local.pg_db] }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
        }
      }
    }
    volume_claim_template {
      metadata { name = "data" }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "local-path"
        resources { requests = { storage = "10Gi" } }
      }
    }
  }
}

resource "kubernetes_service" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.ag.metadata[0].name
  }
  spec {
    selector = { app = "postgres" }
    port {
      port        = 5432
      target_port = 5432
    }
    cluster_ip = "None"
  }
}

# --- TLS -------------------------------------------------------------------
# Access Graph only speaks TLS. The cert needs serverAuth usage and the service
# DNS in a SAN; cert-manager's selfsigned-issuer (already used for teleport-tls
# in 2-teleport) issues it, and Teleport trusts it via the ca.crt in the secret.

resource "kubectl_manifest" "ag_cert" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "teleport-access-graph-tls"
      namespace = kubernetes_namespace.ag.metadata[0].name
    }
    spec = {
      secretName  = "teleport-access-graph-tls"
      duration    = "8760h"
      renewBefore = "720h"
      isCA        = false
      usages      = ["server auth", "digital signature", "key encipherment"]
      dnsNames = [
        local.ag_dns,
        local.ag_service,
        "${local.ag_service}.${local.ag_namespace}",
        "localhost",
      ]
      issuerRef = {
        name  = "selfsigned-issuer"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  })
  depends_on = [kubernetes_namespace.ag]
}

# --- Access Graph ----------------------------------------------------------

resource "helm_release" "access_graph" {
  name       = "teleport-access-graph"
  namespace  = kubernetes_namespace.ag.metadata[0].name
  repository = "https://charts.releases.teleport.dev"
  chart      = "teleport-access-graph"
  version    = var.access_graph_version

  values = [yamlencode({
    postgres = {
      secretName = kubernetes_secret.pg.metadata[0].name
    }
    tls = {
      existingSecretName = "teleport-access-graph-tls"
    }
    # PEM Host CAs of the Teleport clusters allowed to use this instance.
    # Pinned from a file rather than fetched: if the cluster's host CA is ever
    # rotated this must be refreshed, and a stale value should fail loudly
    # rather than silently trust something new.
    clusterHostCAs = [file("${path.module}/host-ca.pem")]
  })]

  depends_on = [
    kubernetes_stateful_set.postgres,
    kubernetes_service.postgres,
    kubectl_manifest.ag_cert,
  ]
}

# --- CA for Teleport -------------------------------------------------------
# Teleport mounts this to verify the Access Graph server cert
# (auth.teleportConfig.access_graph.ca in 2-teleport). Created here rather than
# in 2-teleport because it is derived from the certificate this layer owns, so
# the dependency runs the right way.
data "kubernetes_secret" "ag_tls" {
  metadata {
    name      = "teleport-access-graph-tls"
    namespace = kubernetes_namespace.ag.metadata[0].name
  }
  depends_on = [kubectl_manifest.ag_cert]
}

resource "kubernetes_config_map" "ag_ca_for_teleport" {
  metadata {
    name      = "teleport-access-graph-ca"
    namespace = "teleport-cluster"
  }
  data = {
    # Self-signed via cert-manager, so the issuing CA is the cert itself.
    "ca.pem" = data.kubernetes_secret.ag_tls.data["ca.crt"] != "" ? data.kubernetes_secret.ag_tls.data["ca.crt"] : data.kubernetes_secret.ag_tls.data["tls.crt"]
  }
}
