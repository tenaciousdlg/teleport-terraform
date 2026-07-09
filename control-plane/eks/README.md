# Teleport Control Plane on EKS (Demo)

> ⚠️ **Demo Environment**: optimized for SE demos and rapid iteration. Not for production use.

This control plane is split into five layers to keep infrastructure stable while allowing fast Teleport and RBAC iteration.

**State:** all layers use the **S3 backend** `presales-teleport-demo-tfstate` (versioned, encrypted, lockfile locking — see each layer's `backend.tf`). State is not local. Cross-layer reads (`terraform_remote_state`) resolve from that bucket, so run layers in order and destroy in reverse.

## Layout

```
control-plane/eks/
├── 1-cluster/       # EKS infrastructure (stable, rarely changed)
├── 2-teleport/      # Teleport deployment + supporting AWS/K8s resources
├── 3-rbac/          # SAML/login rules, roles, demo apps, agent managed updates
├── 4-plugins/       # Slack access request plugin
└── 5-access-graph/  # Identity Security (Access Graph) via RDS PostgreSQL + Helm
```

## Quick Start

### 1) Deploy EKS (this step takes ~16 mins to apply)

```bash
cd control-plane/eks/1-cluster
export TF_VAR_region="us-east-2"
export TF_VAR_name="presales"
export TF_VAR_user="you@example.com"
terraform init
terraform apply
```

### 2) Deploy Teleport

```bash
cd ../2-teleport
export TF_VAR_region="us-east-2"
export TF_VAR_proxy_address="presales.teleportdemo.com"
export TF_VAR_user="you@example.com"
export TF_VAR_teleport_version="18.10.0"    # cluster version; check webapi/ping
export TF_VAR_env="dev"                      # live presales value
export TF_VAR_team="platform"
export TF_VAR_okta_metadata_url="https://your-okta.okta.com/app/.../metadata"
terraform init
terraform apply
```

### 3) Apply RBAC + demo apps

```bash
cd ../3-rbac
export TF_VAR_region="us-east-2"
export TF_VAR_proxy_address="presales.teleportdemo.com"
export TF_VAR_okta_metadata_url="https://your-okta.okta.com/app/.../metadata"
export TF_VAR_dev_team="dev"
export TF_VAR_prod_team="platform"
terraform init
terraform apply
```

## RBAC Model

All access is scoped using `env` and `team` labels:

- **dev access**: `dev-access` with `env=dev`, `team=dev`
- **platform dev access**: `platform-dev-access` with `env=dev`, `team=*`
- **prod access**: `prod-readonly-access` and `prod-access` with `env=prod`, `team=platform`

Access lists are SCIM‑managed and must match Okta group displayNames exactly:

- `Everyone` → `base-user`
- `devs` → `dev-access`, `dev-requester`
- `engineers` → `platform-dev-access`, `dev-reviewer`, `prod-requester`

Request/review roles (`dev-requester`, `prod-requester`, `dev-reviewer`) handle elevation and approvals.

Ensure apps, DBs, nodes, and desktops are labeled with the same keys to align with roles.

## SCIM Checklist

- Enable SCIM in Teleport and associate it with your SAML connector.
- In Okta, configure SCIM provisioning with the Teleport SCIM base URL and client credentials.
- Ensure Okta group `displayName` values match Access List titles exactly:
  - `Everyone`
  - `devs`
  - `engineers`
- Apply the `3-rbac` layer to create roles and SCIM Access Lists.

## SCIM/Okta Wiring (Minimal)

- Teleport: Integrations → SCIM → create integration, select your SAML connector, copy Base URL + Client ID/Secret.
- Okta: Provisioning → SCIM → paste Base URL + Client ID/Secret, enable Group Push/Assignments.
- Access Lists: `spec.title` **must** equal Okta group `displayName` (case‑sensitive).

## Teardown

Destroy in reverse layer order: `5-access-graph` → `4-plugins` → `3-rbac` → `2-teleport` → `1-cluster`.

### 2-teleport: CRD finalizer hang

`terraform destroy` will hang on Teleport CRD deletion. The operator is already gone so
nothing can service the finalizers. While the destroy is hanging (or before running it),
strip the finalizers in a separate terminal:

```bash
kubectl get crds -o name | grep teleport \
  | xargs -I{} kubectl patch {} -p '{"metadata":{"finalizers":[]}}' --type=merge
```

The destroy will complete immediately after.

### 1-cluster: straggler security groups

If any EC2 instances were manually added to the VPC (e.g. a Windows Desktop Service host
added outside of a data-plane Terraform module), their security groups will not be in
Terraform state and will block VPC deletion.

Symptoms: `aws_vpc.this` stuck destroying for 30+ minutes with no ENIs or load balancers present.

Fix: find and delete the orphaned security group(s):

```bash
VPC_ID="<your-vpc-id>"
REGION="us-east-2"

aws ec2 describe-security-groups --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" \
  --output table

# Delete each non-default SG found
aws ec2 delete-security-group --region $REGION --group-id <sg-id>
```

Then re-run `terraform destroy`.

## Teleport Updates (control plane + managed agents)

Two steps, control plane first — agents must never lead the auth server:

```bash
# 1) Bump the control plane
cd 2-teleport
export TF_VAR_teleport_version=18.11.0   # the new version
terraform apply

# 2) Point agents + client tools at it (never above the cluster version)
cd ../3-rbac
export TF_VAR_autoupdate_target_version=18.11.0
terraform apply
```

`3-rbac` manages the `TeleportAutoupdateConfigV1` (schedule Mon–Fri 02:00 UTC, halt-on-error; `tools` mode enabled) and `TeleportAutoupdateVersionV1` (the target). Agents roll in the next window; `tsh`/`tctl` get the target via managed client-tools updates. Confirm with `curl https://<proxy>/v1/webapi/find | jq .auto_update`.

Running presales intentionally on the latest release is the point — it surfaces release issues before they hit a demo.

## Pod Security

The `teleport-cluster` namespace enforces Pod Security Standards `baseline` (`pod-security.kubernetes.io/enforce=baseline`, set in `2-teleport`). The Teleport chart pods comply; new workloads in that namespace must too.
