# presales.teleportdemo.com — state restore notes (2026-07-08)

Local Terraform state for all layers was destroyed on 2026-07-07 and rebuilt
via `terraform import` against the live cluster on branch `restore/eks-state`.
Layers 1–4 are import-clean (no replacements/destroys in plan); layer
5-access-graph was never deployed — it has no state on purpose.

## Operating values (the live stack was built with these)

```bash
# all layers
export TF_VAR_user=dlg@goteleport.com
export TF_VAR_region=us-east-2
export TF_VAR_env=dev            # NOT the tf default (prod) — live tags are env=dev

# 1-cluster
export TF_VAR_name=presales TF_VAR_ver_cluster=1.35

# 2-teleport
export TF_VAR_proxy_address=presales.teleportdemo.com
export TF_VAR_domain_name=teleportdemo.com
export TF_VAR_teleport_version=18.10.3       # cluster-advertised; check webapi/ping
export TF_VAR_access_graph_enabled=true      # TAG deployed 2026-07-09 (layer 5)

# 3-rbac — IdP identifiers stay out of this (public) repo; recover from the
# live connectors when needed (resource kind is teleportsamlconnectors):
#   kubectl get teleportsamlconnectors -n teleport-cluster -o yaml | grep entity_descriptor_url
export TF_VAR_okta_metadata_url="<from live okta-integrator connector>"
export TF_VAR_okta_preview_metadata_url="<from live okta-preview connector>"
export TF_VAR_autoupdate_mode=enabled
export TF_VAR_enable_okta_preview=true               # okta-preview connector is live
# REQUIRED — omitting it plans a DESTROY of the live autoupdate_version CR
# (var default "" gates the resource off). Live value:
#   kubectl get teleportautoupdateversionsv1 -n teleport-cluster -o yaml
export TF_VAR_autoupdate_target_version=18.10.3      # keep = cluster version

# 4-plugins
export TF_VAR_plugin_chart_version=18.7.1    # PIN — tf default "" means latest; live is 18.7.1
# slack_channel_id: helm get values teleport-plugin-slack -n teleport-plugins
# slack_bot_token: read from the live k8s secret when needed:
#   kubectl get secret teleport-plugin-slack-credentials -n teleport-plugins -o jsonpath='{.data.token}' | base64 -d
```

# 5-access-graph (deployed 2026-07-09)
# Standard RDS Postgres 16.14 (db.t4g.small) — Aurora is SCP-denied in this
# account (rds:CreateDBCluster, org policy p-92pxkqrp). db_password lives in
# the k8s secret teleport-access-graph-postgres (and in state):
#   kubectl get secret teleport-access-graph-postgres -n teleport-access-graph -o jsonpath='{.data.uri}' | base64 -d

# 5-access-graph also requires (added after these notes were first written):
export TF_VAR_teleport_host_ca="$(curl -s 'https://presales.teleportdemo.com/webapi/auth/export?type=tls-host')"

# 5-access-graph — TAG uses PASSWORDLESS RDS IAM auth (2026-07-09)
# TAG assumes IRSA role teleport-access-graph-rds-dev and connects to RDS with
# short-lived IAM tokens (no stored password). Pieces: iam.tf (IRSA role +
# rds-db:connect policy), the DB user holds rds_iam (GRANT rds_iam TO
# access_graph — run once from an in-cluster psql pod), helm values set
# postgres.aws.enabled=true + a passwordless connectionString + the SA
# eks.amazonaws.com/role-arn annotation.
#   - The kubernetes_secret teleport-access-graph-postgres (password URI) is now
#     UNUSED by TAG (kept as fallback; safe to remove later).
#   - RDS master password still exists (RDS requires one) but TAG doesn't use it.
#   - GOTCHA: the OIDC trust-policy condition key must be the provider URL
#     (oidc.eks.../id/XXX:sub), NOT the full ARN — strip the arn prefix with a
#     plain replace(), not a regex.
#   - PENDING: helm release was left "failed" (wait timed out during the initial
#     bad-trust-policy crashloop; runtime is healthy). Reconcile with:
#     terraform apply -target=helm_release.access_graph  (flips it to deployed).

## Known residual drift

NONE as of 2026-08-04: all five layers plan "No changes" after the drift
cleanup + 18.10.0 → 18.10.3 upgrade (helm rev 6, addon patch bumps applied,
audit_log values converged, autoupdate CR at 18.10.3 — agents roll on the
regular schedule). The 2026-07-09 "failed" helm status was a false failure:
the 300s wait deadline expired after the manifests had applied (the audit_log
config was already live in the auth ConfigMap); helm_release timeout is now
600s. Reminders that still apply:

- 1-cluster: `most_recent = true` on EKS addons means future plans will
  periodically offer patch bumps — expected, apply at will.
  `bootstrap_self_managed_addons = false` remains create-only — removing it
  would plan a full cluster replacement.
- 2-teleport: a helm_release change makes the route53 record diffs show
  `(known after apply)` — cascade of the LB data source, not DNS drift.
- 3-rbac: prod-access (the 2026-07-29 destroy casualty) is properly back in
  state.

## Next-change checklist

1. `terraform plan` per layer with the exports above; expect only the diffs
   listed here. Anything else: stop and investigate.
2. ~~Consider migrating all layers to a remote backend~~ DONE — all five
   layers use s3://presales-teleport-demo-tfstate (backend.tf per layer);
   the terraform.tfstate files still sitting in 1-cluster..4-plugins are
   pre-migration leftovers, safe to delete.
