# Cloud Control Plane (Teleport SaaS)

This template configures a Teleport Cloud tenant using the Teleport Terraform provider. There is no infrastructure layer to provision.

**In this repo it manages the team demo tenant** (moved here 2026-10-13 from a
root that lived outside any repo). `2-teleport` holds the SAML connector and
auth preference; `3-rbac` holds that tenant's own roles and Access Lists, not
the canonical `teleport-rbac` model, which stays the template in rev-tech.
Before the move both were planned against the live tenant and matched.

- **State:** S3, bucket `dlg-dlgdemo-teleport-terraform-state` (SE AWS
  account, us-east-2, versioned, SSE-S3, public access blocked), one key per
  layer, `use_lockfile` locking. AWS credentials come from the shell's
  `AWS_PROFILE`.
- **Teleport credentials:** your own tsh session works, with no bot and no
  MFA prompt for a plan:
  `TF_TELEPORT_PROFILE_NAME=<tenant> TF_TELEPORT_PROFILE_PATH=~/.tsh`.
- **Values:** gitignored `dlgdemo.tfvars` in each layer (copy in Vault at
  `secret/teleport/dlgdemo-tfvars`). Always `-var-file=dlgdemo.tfvars`.
- **The connector maps `terraform-provider`** for `Everyone` and
  `security-team`. That was added on the live tenant by hand and is adopted
  in code; removing it removes the role SSO users run this provider with.

## Layout

```
control-plane/cloud/
├── 1-cluster/   # no-op for SaaS
├── 2-teleport/  # SAML connector + auth preference
└── 3-rbac/      # roles and access lists
```

## Prerequisites

- Teleport Cloud tenant
- `tctl` available for generating Terraform credentials
- Terraform v1.6+
- Okta SAML app configured with your tenant's ACS URL

## Usage

### 1) No-op cluster layer

Nothing to provision for SaaS — skip this directory.

### 2) SAML connector + auth preference

```bash
cd control-plane/cloud/2-teleport
export TF_VAR_proxy_address="your-tenant.teleport.sh"
export TF_VAR_okta_metadata_url="https://your-okta.okta.com/app/.../metadata"

eval $(tctl terraform env)
terraform init
terraform apply
```

This creates the Okta SAML connector and sets SAML as the cluster auth method.
All authenticated users receive `base-user` via the connector's `attributes_to_roles`.

### 3) RBAC

```bash
cd ../3-rbac
export TF_VAR_proxy_address="your-tenant.teleport.sh"

eval $(tctl terraform env)
terraform init
```

Copy the example vars file and populate your user lists:

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — add emails for devs, senior_devs, engineers
terraform apply
```

## RBAC Model

Three-tier persona model — roles are managed by `modules/teleport-rbac` and access list membership is Terraform-managed (no SCIM required):

| Access list | Grants |
|---|---|
| `devs` | `dev-access`, `dev-auto-access`, `dev-requester` |
| `senior-devs` | `platform-dev-access`, `dev-auto-access`, `senior-dev-requester` |
| `engineers` | `platform-dev-access`, `dev-auto-access`, `prod-readonly-access`, `dev-reviewer`, `prod-requester`, `prod-reviewer`, `editor`, `auditor` |

`base-user` is assigned automatically to all authenticated users by the SAML connector.

Resources must be labeled `env=dev`/`team=dev` (dev tier) or `env=prod`/`team=platform` (prod tier) to match the role label matchers.
