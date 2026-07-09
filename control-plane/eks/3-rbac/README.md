# EKS Control Plane — Layer 3: RBAC

Configures Teleport roles, access lists, SAML connector (Okta), and auth preference via the Teleport Kubernetes operator (TeleportRoleV7 CRDs). Defines the three-tier demo role hierarchy: `devs`, `senior-devs`, `engineers`.

Also manages **agent managed updates**: `TeleportAutoupdateConfigV1` (schedule Mon–Fri 02:00 UTC, halt-on-error, `tools` mode following `autoupdate_mode`) and `TeleportAutoupdateVersionV1` (gated on `autoupdate_target_version` — empty means no version resource and agents stay put). Never set the target above the cluster version; bump `2-teleport` first.

Reads layer 1's remote state (S3) to configure the Kubernetes provider that applies the CRDs — so `1-cluster` must be applied first.

See [../README.md](../README.md) for the full EKS control plane deployment guide, layer sequence, and the update workflow.
