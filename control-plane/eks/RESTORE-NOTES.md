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
export TF_VAR_teleport_version=18.7.6        # cluster-advertised; check webapi/ping
export TF_VAR_access_graph_enabled=false

# 3-rbac (metadata URLs recovered from live connectors — not secrets)
export TF_VAR_okta_metadata_url="https://integrator-7036658.okta.com/app/exktcdx5a7sdDckm2697/sso/saml/metadata"
export TF_VAR_okta_preview_metadata_url="https://gravitational-preview.oktapreview.com/app/exkftll0o8X4SCO6k1d7/sso/saml/metadata"
export TF_VAR_autoupdate_mode=enabled
# enable_okta_preview=true (okta-preview connector is live)

# 4-plugins
export TF_VAR_plugin_chart_version=18.7.1    # PIN — tf default "" means latest; live is 18.7.1
export TF_VAR_slack_channel_id=C0AKS5M5XGQ
# slack_bot_token: read from the live k8s secret when needed:
#   kubectl get secret teleport-plugin-slack-credentials -n teleport-plugins -o jsonpath='{.data.token}' | base64 -d
```

## Known residual drift (review before the next real apply)

- 1-cluster: 15 in-place diffs — tag reconciliation + EKS addons offering
  version bumps (`most_recent = true`). `bootstrap_self_managed_addons = false`
  was added to main.tf to match the live cluster (create-only attr; removing
  it would plan a full cluster replacement).
- 2-teleport: namespace label `pod-security.kubernetes.io/enforce=baseline`
  exists in config but not live — applying would newly enforce PSS baseline.
  Decide: keep (hardening) or drop from config.
- 3/4: remaining diffs are provider-default/yaml normalization (semantic no-ops).

## Next-change checklist

1. `terraform plan` per layer with the exports above; expect only the diffs
   listed here. Anything else: stop and investigate.
2. Consider migrating all layers to a remote backend (an S3 bucket + DynamoDB
   tables already exist from 2-teleport's own resources) so local state files
   are never again the only copy.
