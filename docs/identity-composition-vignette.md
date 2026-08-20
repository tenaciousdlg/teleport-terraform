# Vignette: Identity Composition — ABAC, JIT, and Zero Standing Privilege

Demo arc: **Identity → Authentication → Authorization → Audit**. Maps to the
Modular Demo Framework as a V1 (SSH) + V7 (Compliance) hybrid with the JIT
transition hook. Runs against the EKS control plane in this repo
(`control-plane/eks/3-rbac`); every command below was verified live on
v18.10.3. Replace `<proxy>` / `<you>` with your cluster and username.

The through-line to say out loud: *the IdP says who you are, access lists
say what you've been granted, roles are templates — Teleport composes the
three at login, and everything that results is attributable.*

---

## Beat 1 — Identity: traits compose, nobody wins

**SAY:** Your IdP asserts attributes; Teleport access lists can grant the
same attribute. Neither overwrites the other — values union per key and
dedupe, so identity is *composed*, not overwritten.

**DO:**

```bash
# What the IdP asserted (stored on the user at login)
tctl get users/<you> --format=json | jq '.[0].spec.traits["team-name"]'

# What the access list grants
tctl get access_list --format=json | jq '.[] |
  select(.spec.grants.traits != null) |
  {list: .metadata.name, grants: .spec.grants.traits}'

# What the certificate actually carries — the union
tsh status --format=json | jq '.active.traits["team-name"]'
```

**SEE:** IdP says `["platform"]`, the engineers list grants `["dev"]`, the
cert carries `["platform","dev"]`. Identical values collapse to one — grants
are idempotent overlays, never conflicts.

Gotchas worth narrating: the merge happens only in the login hook (grant
changes are invisible until next login), and `tctl users get` shows only the
IdP side — the cert is the truth.

## Beat 2 — Authentication: SSO + WebAuthn + device

**SAY:** One SSO round issues a short-lived certificate; WebAuthn is the
only second factor; device trust binds the cert to enrolled hardware.

**DO:** `tsh logout --proxy=<proxy> && tsh login --proxy=<proxy>` then
`tsh status` — point at `Valid until` (hours, not credentials-forever) and
the `teleport-device-*` extensions.

## Beat 3 — Authorization: one ABAC role + JIT everything

**SAY:** There is no per-team role sprawl. One role — `team-access` — is
granted to every tier, and *what it reaches* is decided by the identity
composed in Beat 1: `node_labels: team = ["{{external[\"team-name\"]}}"]`.
Move a user between IdP groups and their access follows at next login,
with zero role changes.

**DO:**

```bash
tctl get roles/team-access --format=json | jq '.[0].spec.allow.node_labels'
tsh ls   # scoped to YOUR teams' dev nodes
```

**SAY (ZSP):** Nobody — including the platform owner — holds standing
admin. Watch a write fail, then JIT it:

```bash
tctl lock --user=bob --ttl=1m        # ERROR: access denied
tsh request create --roles editor --reason "change window 1234"
#   → auto-approved by an access monitoring rule, auto-assumed, 4h max
tctl lock --user=bob --ttl=1m        # Created
```

**SAY (SoD talk track):** the same tier holds requester *and* reviewer —
and that's deliberate demo material, not a hole: Teleport structurally
refuses self-review, so approval always crosses people even when roles
overlap. Prod elevation requires a reason; the MFA-per-session variant
(`prod-access-mfa`) is deliberately excluded from auto-approval so one
request in the demo stays pending for the human-review beat.

**SAY (governance):** every grant above came from an access list with a
real owner and a review schedule — SCIM-synced where the IdP supports it,
explicit + quarterly-audited (`visiting-ses`) where it doesn't, same
governance surface either way. Local users compose identically: add them
to a list or set traits on the user resource.

## Beat 4 — Audit: everything attributable

**SAY:** No shared accounts anywhere in the path. The SSH login is your
email's local part, auto-provisioned on the host at first session.

**DO:**

```bash
tsh ssh <you>@<node> "id"   # uid created on the fly, teleport-keep group
```

**SEE:** in the web UI Audit page: the access request with its reason, the
automatic review by the monitoring rule, session start with the personal
login, enhanced-recording command events — `sudo` on-host included, still
attributed to the named user.

---

## Reset between runs

Elevation expires on its own (4h). For a clean re-run:
`tsh logout --proxy=<proxy>` and log back in — the demo starts at Beat 1's
trait composition every time.
