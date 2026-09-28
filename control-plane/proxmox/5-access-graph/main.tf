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
    #
    # THE DESIGN WORKED EXACTLY AS WRITTEN, AND IT STILL COST A DAY.
    # REFRESHED 2026-09-27. This file held `O=teleport.chrisdlg.com` dated
    # Sep 8, the HOST CA OF THE DESTROYED CLUSTER. A cluster rebuild mints a
    # new host CA, so after the move to teleport.heronwright.com the Access
    # Graph was pinned to a CA that no longer signs anything, rejected auth's
    # client certificate, and the Web UI reported "the Access Graph service
    # cannot be contacted". Auth logged, every five seconds:
    #     Access graph registration failed ...
    #     x509: certificate signed by unknown authority,
    #     rpc error: ... could not find host CA
    # Both pods were Running 1/1 and the Access Graph's own log was clean
    # after "Successfully connected to the database", because nothing was
    # wrong on its side: it was correctly refusing a certificate signed by a
    # CA it had never been told about.
    #
    # NOTE WHAT THE PIN DID AND DID NOT BUY. It refused to trust the new
    # cluster silently, which is the whole point and is right. What it does
    # not do is surface staleness at PLAN time, so the failure shows up in the
    # product UI instead of in a diff. A cluster rebuild must refresh this
    # file in the same pass that creates the cluster:
    #
    #   tctl auth export --type=tls-host > host-ca.pem   # run against the NEW cluster
    #
    # See the CA-comparison guard below, which turns "stale pin" from a
    # runtime symptom into a plan-time one without weakening the pin. It is in
    # two parts on purpose: a `check` block WARNS on every plan, including a
    # no-change plan, which is exactly when a stale pin is invisible; and a
    # `precondition` on this resource FAILS the apply outright. A `check`
    # alone only warns, and a warning in a long plan is easy to scroll past.
    clusterHostCAs = [file("${path.module}/host-ca.pem")]
  })]

  # HARD STOP, not just a warning. The `check` block below reports a stale pin
  # on every plan; this refuses to apply one. Both exist because they fire in
  # different places and a warning alone was not enough to have caught this.
  lifecycle {
    precondition {
      condition = can(regex(
        replace(data.terraform_remote_state.teleport.outputs.cluster_name, ".", "\\."),
        data.tls_certificate.pinned_host_ca.certificates[0].subject
      ))
      error_message = "host-ca.pem is pinned to a different Teleport cluster than this layer is applying to. A cluster rebuild mints a new host CA. Refresh it against the NEW cluster: tctl auth export --type=tls-host > host-ca.pem"
    }
  }

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

# --- host-CA staleness check ------------------------------------------------
#
# WHY THIS EXISTS. `clusterHostCAs` above is pinned to a checked-in PEM, on
# purpose, so the Access Graph cannot silently start trusting a different
# Teleport cluster. That property is worth keeping. The cost is that a stale
# pin is invisible until Teleport tries to register and the Web UI says the
# service cannot be contacted, which is what happened on 2026-09-27: the file
# still held the destroyed chrisdlg cluster's host CA, both pods reported
# Running 1/1, and the only symptom was in the product.
#
# This turns that into an apply-time failure WITHOUT weakening the pin. A
# Teleport host CA is issued with the cluster name as its subject
# (O=<cluster>, CN=<cluster>), so if the pinned certificate's subject does not
# name the cluster this layer is being applied to, the pin is for a different
# cluster and the apply stops with an instruction instead of succeeding into a
# broken feature.
#
# Parsed with the `tls` provider, which is already required here, so this adds
# no dependency, no SSH and no plan-time command.
data "tls_certificate" "pinned_host_ca" {
  content = file("${path.module}/host-ca.pem")
}

check "host_ca_matches_cluster" {
  assert {
    condition = can(regex(
      replace(data.terraform_remote_state.teleport.outputs.cluster_name, ".", "\\."),
      data.tls_certificate.pinned_host_ca.certificates[0].subject
    ))
    error_message = join("", [
      "host-ca.pem is pinned to a DIFFERENT Teleport cluster. Pinned subject: '",
      data.tls_certificate.pinned_host_ca.certificates[0].subject,
      "', but this layer is applying to cluster '",
      data.terraform_remote_state.teleport.outputs.cluster_name,
      "'. A cluster rebuild mints a new host CA. Refresh it against the NEW ",
      "cluster with: tctl auth export --type=tls-host > host-ca.pem",
    ])
  }
}
