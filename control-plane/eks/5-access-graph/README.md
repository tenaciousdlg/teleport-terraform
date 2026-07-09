# Access Graph (Identity Security)

Deploys the Teleport Access Graph service (TAG), which powers the **Identity Security** features: visualising all access paths, identifying blast radius, and surfacing crown jewels.

Requires Teleport Enterprise with the Identity Security add-on enabled in your license.

## What It Deploys

**AWS:**
- RDS PostgreSQL 16 instance (`db.t4g.small`, gp3, encrypted) — persistent storage for the graph. **Not Aurora**: `rds:CreateDBCluster` is denied by the org SCP in the presales account, so this uses a standard `aws_db_instance` (see `rds.tf`).
- IAM database authentication enabled on the instance.
- DB subnet group in the EKS private subnets + security group allowing PostgreSQL (5432) from the VPC.
- **IRSA role** `teleport-access-graph-rds-<env>` (`iam.tf`) — the TAG service account assumes it to `rds-db:connect` as the `access_graph` DB user. This is what makes the DB connection **passwordless**.

**Kubernetes:**
- Namespace `teleport-access-graph`
- Secret `teleport-access-graph-tls` — self-signed TLS cert for the gRPC listener
- Secret `teleport-access-graph-postgres` — password connection URI. **Retained but unused**: TAG connects via IAM auth, not this secret. Kept as a fallback; safe to remove once IAM auth is proven.
- ConfigMap `teleport-access-graph-ca` (in `teleport-cluster` namespace) — mounted by the Teleport auth pods to verify the gRPC TLS cert
- Helm release `teleport-access-graph` (memory request 512Mi / limit 1Gi — TAG's initial import self-starves without this on a small shared node)

## Passwordless database auth

TAG authenticates to RDS with short-lived IAM tokens instead of a stored password (aligns with the no-static-secrets posture). Three pieces make it work, all in this layer except the grant:

1. RDS `iam_database_authentication_enabled = true` (`rds.tf`).
2. IRSA role + `rds-db:connect` policy scoped to the `access_graph` DB user (`iam.tf`); the Helm values annotate the service account with the role ARN and set `postgres.aws.enabled = true` with a passwordless `connectionString`.
3. **One-time DB grant** so the user accepts IAM tokens — run from an in-cluster psql pod (the RDS is in private subnets):
   ```bash
   PW="$(kubectl get secret teleport-access-graph-postgres -n teleport-access-graph \
     -o jsonpath='{.data.uri}' | base64 -d | sed -E 's#.*://[^:]+:([^@]+)@.*#\1#')"
   kubectl run pg-grant --rm -i --restart=Never -n teleport-access-graph \
     --image=postgres:16 --env="PGPASSWORD=$PW" --command -- \
     psql "host=<rds-endpoint> port=5432 dbname=access_graph user=access_graph sslmode=require" \
     -c "GRANT rds_iam TO access_graph;"
   ```

> **IRSA gotcha:** the trust-policy condition key must be the OIDC provider **URL** (`oidc.eks.<region>.amazonaws.com/id/XXXX:sub`), not the full provider ARN. Strip the ARN prefix with a plain `replace()`, not a regex (`iam.tf` does this).

## Prerequisites

- Layers 1–3 applied (`1-cluster`, `2-teleport`, `3-rbac`)
- Teleport Enterprise license with Identity Security enabled
- `tsh login` / `eval $(tctl terraform env)` active (only for reading the host CA; this layer's own resources are AWS/K8s)

## Usage

### Step 1: Get the Teleport host CA

```bash
export TF_VAR_teleport_host_ca="$(curl -s 'https://presales.teleportdemo.com/webapi/auth/export?type=tls-host')"
```

### Step 2: Apply this layer

```bash
# See terraform.tfvars.example for all required variables
export TF_VAR_proxy_address="presales.teleportdemo.com"
export TF_VAR_env="dev"                     # matches the live stack
export TF_VAR_db_password="<rds master password>"   # RDS requires one; TAG does not use it
# TF_VAR_teleport_host_ca set above
terraform init      # S3 backend (see below)
terraform apply
```

Then run the **one-time `rds_iam` grant** from the passwordless section above.

### Step 3: Enable Access Graph in the Teleport cluster

Re-apply `2-teleport` with `TF_VAR_access_graph_enabled=true` (this is already the live value for presales). It updates the Teleport Helm release to enable `access_graph`, point auth at the gRPC endpoint, and mount the CA. **The auth pods restart** — do this outside demo hours.

### Step 4: Verify

```bash
kubectl -n teleport-access-graph rollout status deployment/teleport-access-graph
# healthy = pod Ready, 0 "failed to generate RDS auth token" in logs
```

Then open the Teleport Web UI: **Identity Security → Graph Explorer**.

## Demo Points

- **Graph Explorer**: visualise which users can access which resources and through which roles
- **Crown Jewels**: identify the most-accessed or highest-privilege resources
- **Blast radius**: select any identity and see everything it can reach
- **Role changes reflected in real-time**: apply a new role in 3-rbac and watch the graph update

## RBAC

Users with the `platform-dev-access` role can view Access Graph (the `access_graph` resource rule, `list` + `read`, is set on that role in the shared RBAC module). In this demo that's the `engineers` and `senior-devs` groups.

## Inputs

| Variable | Default | Description |
|---|---|---|
| `proxy_address` | required | Teleport proxy hostname |
| `region` | `us-east-2` | AWS region |
| `env` | `prod` (live: `dev`) | Environment label |
| `team` | `platform` | Team label |
| `teleport_namespace` | `teleport-cluster` | Teleport Kubernetes namespace |
| `db_password` | required | RDS **master** password. Required by RDS; TAG authenticates via IAM, not this. |
| `teleport_host_ca` | required | PEM-encoded Teleport host CA |
| `access_graph_chart_version` | `""` | Helm chart version (empty = latest) |

## Outputs

| Output | Description |
|---|---|
| `access_graph_endpoint` | gRPC endpoint (internal Kubernetes DNS) |
| `rds_endpoint` | RDS instance address |
| `next_steps` | Post-deployment instructions |

## State

This layer (like all eks layers) uses the **S3 backend** `presales-teleport-demo-tfstate` (`backend.tf`), versioned and encrypted with lockfile-based locking. State is not local.
