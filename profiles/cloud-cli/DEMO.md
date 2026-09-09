# cloud-cli demo — command cheat-sheet

Cloud-provider API access through Teleport App Access. Two apps: `azure-cli`
and `google-cloud-cli`. CLI/API only by design (Portal/Console access is a
separate Teleport-as-IdP path).

STATUS: profile DESTROYED 2026-09-01 (dormant, was ~$45/mo always-on). Rebuild
= `terraform apply` in this dir (needs local az + gcloud auth and a Teleport
identity with token perms). Commands below then work verbatim.

## Azure

    tsh apps login azure-cli --azure-identity teleport-azure
    tsh az vm list -g rg-dlg-teleport-demo -o table

- `--azure-identity teleport-azure` — selects WHICH Azure managed identity
  Teleport assumes for you. The module creates it (name hardcoded
  "teleport-azure"), attaches it to the agent VM, and the `azure-cli` app is
  registered to allow it (by client id). Teleport makes you name it even when
  there's only one — it's the "acting as" selector. Accepts the identity name
  or its full resource id.
- `-g rg-dlg-teleport-demo` — a native `az` flag, REQUIRED here because the
  identity's `Reader` role is scoped to ONLY that resource group
  (`azurerm_role_assignment.reader`, scope = the RG). Without `-g`, `az vm list`
  queries the whole subscription, which the identity can't read → empty result.
  The flag is the visible edge of the least-privilege boundary Teleport
  enforced — say that in the demo, it's the point. Name comes from the module
  default `var.resource_group_name` ("rg-dlg-teleport-demo"); the profile
  doesn't override it.

## GCP

    tsh apps login google-cloud-cli --gcp-service-account teleport-vm-viewer
    tsh gcloud compute instances list

- `--gcp-service-account teleport-vm-viewer` — the symmetric selector: which
  service account the controlling SA impersonates. (Sentinel's flow omitted it
  because a sole authorized SA lets tsh default; name it live for clarity.)
- No scoping flag on the list: `teleport-vm-viewer` holds `roles/viewer` at the
  PROJECT level (GCP has no resource-group concept — IAM is project/folder/org),
  so `gcloud compute instances list` lists the whole project and reads like an
  unmodified gcloud command. That's why GCP "feels" native: the scope lives in
  the identity, not the command.

## The asymmetry (the teachable contrast)

Both clouds pick an identity at LOGIN (`--azure-identity` / `--gcp-service-
account`). They differ only at QUERY time, purely because of how each scope was
set:

- Azure `Reader` scoped to one resource group → you must pass `-g`.
- GCP `Viewer` scoped to the whole project → nothing extra.

Make Azure "native" too by widening the role assignment to subscription scope
(then `-g` is optional) — at the cost of a looser least-privilege story. Keeping
it RG-scoped is the better demo.

## Scaling / customizing

- RG name: set `var.resource_group_name` (module default rg-dlg-teleport-demo).
  Two SEs in one subscription collide unless they override it — parameterize
  per-user before any team adoption.
- More Azure reach: add `azurerm_role_assignment` entries (more RGs) or lift the
  scope to the subscription; mirror any new RG in the join token's `azure.allow`.
- The identity name "teleport-azure" is hardcoded in the module — edit there if
  you ever need more than one identity per deployment.
