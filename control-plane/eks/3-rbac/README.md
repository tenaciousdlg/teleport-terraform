# EKS Control Plane — Layer 3: RBAC

Configures Teleport roles, access lists, SAML connectors (Okta), and agent
managed updates via the Teleport Kubernetes operator (CRDs applied through
the `kubectl` provider).

## Identity chain

```
Okta groups ──SCIM push──▶ Access Lists ──grants──▶ Roles ──labels──▶ Resources
     │                          │
     └──SAML assertion──▶ user traits ──union──▶ certificate traits
```

- **Connector maps one thing**: `Everyone → base-user`. Every other role is
  granted through SCIM-synced access lists (`devs`, `senior-devs`,
  `engineers`) — onboarding another SSO means mapping its groups to the same
  roles, nothing else changes.
- **Gotcha — the `everyone` list is memberless**: Okta cannot group-push its
  built-in Everyone group, so that list's grants reach nobody. It exists for
  parity only; `base-user` comes from the connector mapping.
- **No login rule, on purpose**: every SAML assertion attribute lands as a
  user trait verbatim (`username`, `groups`, `aws_role_arns`, `team-name`).
  A `traits_map` REPLACES the trait set — an earlier rule here silently
  starved every role template of its inputs. Logins are the email local part
  via `{{email.local(external.username)}}`.

## ABAC: the `team-access` role

One role, shared by all tiers; per-user scope comes from the IdP-asserted
`team-name` trait (Okta derives it from group membership) plus any
`team-name` values granted by access lists. Teleport **unions** trait values
from both sources at login and dedupes — neither side wins a collision.

- Template gotcha: hyphenated trait keys need bracket-index form —
  `{{external["team-name"]}}`. The dotted form parses `-` as subtraction and
  the operator rejects the role.
- Personal login only (no shared `ubuntu`/`ec2-user`): with
  `create_host_user_mode: keep`, every session is a named host user created
  on first login — full attribution in the audit log. Privileged OS group
  membership comes from `host_groups` (e.g. `wheel`), which unions across
  all matched roles; on-host `sudo`/`su` stays attributed to the named user
  via enhanced session recording (BPF).

## JIT / zero standing privilege

- Requesters (`dev-`, `senior-dev-`, `prod-requester`) are bounded:
  `max_duration: 4h` — no long-lived approved elevations.
- Prod-tier requests **require a reason**; an access monitoring rule
  auto-approves the demo flow based on it.
- Prod SSH is JIT-only by design: `prod-readonly-access` matches the prod
  node's labels but defines no logins.

## Kubernetes: two enforcement layers

`kubernetes_labels` controls which clusters a role can reach;
`kubernetes_resources` pins namespaces regardless of kube group — dev roles
to namespace `dev` (all verbs), prod to `prod`, read-only to
get/list/watch.

## Access list governance

Owners are a real user (they run membership reviews and show in audit), set
via `TF_VAR_access_list_owner` — the identity stays out of this public repo
like the IdP URLs (the gitleaks pre-commit hook enforces both).

## Agent managed updates

`TeleportAutoupdateConfigV1` (schedule Mon–Fri 02:00 UTC, halt-on-error,
`tools` mode following `autoupdate_mode`) and `TeleportAutoupdateVersionV1`
(gated on `autoupdate_target_version` — empty means no version resource and
agents stay put). Never set the target above the cluster version; bump
`2-teleport` first.

## Plumbing

Reads layer 1's remote state (S3) to configure the Kubernetes provider that
applies the CRDs — so `1-cluster` must be applied first. Required local-only
variables (owner identity, IdP metadata URLs) are documented in
[../RESTORE-NOTES.md](../RESTORE-NOTES.md).

See [../README.md](../README.md) for the full EKS control plane deployment
guide, layer sequence, and the update workflow.
