# modules/proxmox-teleport-host

A Teleport agent host on a Proxmox LXC: the container, a `bound_keypair` join
token, Teleport installed, `/etc/teleport.yaml` templated, and an optional
payload script for whatever the host actually serves.

**Why this exists.** `self-database-lxc` fuses "make an LXC" to "install a
database engine", and every other data-plane module is AWS. The portable half
of the data plane — SSH nodes, app hosts, Machine ID targets — needs the
container and the agent without the engine.

**Two deliberate differences from `self-database-lxc`:**

1. `initial_public_key`, not `registration_secret`. A public key is not a
   secret, so the token is fully described in the repo and nothing sensitive
   lands in terraform state. `self-database-lxc` predates that default and
   still writes a `random_password` into state.
2. `terraform_data`, not `null_resource`.

## The two-phase bootstrap, and why it is not avoidable

A token cannot reference a key that does not exist yet, and the key must be
generated **on the host** so its private half never enters terraform state.
So a brand-new host takes two applies. This is not new: `3-rbac/agents.tf` and
`3-rbac/terraform-bot.tf` already work this way.

```sh
# PHASE 1 — container + Teleport + keypair. The token is not created yet, so
# pass any placeholder for initial_public_key.
terraform apply -target=module.<name>.proxmox_virtual_environment_container.host \
                -target=module.<name>.terraform_data.bootstrap

# Read the public half it generated:
ssh root@hollowtree 'pct exec <vmid> -- cat /var/lib/teleport-bkp/static-key.pub'

# PHASE 2 — paste that into the layer's initial_public_key, then:
terraform apply
```

`tbot keypair create` **pings the proxy** to determine the signature algorithm
suite, so the proxy must resolve and be reachable from inside the container
before phase 1 will complete. Re-running it WITHOUT `--overwrite` reprints the
existing key rather than minting one the token does not know about.

## Static keys mean `insecure` recovery, and that is correct

The token sets `recovery.mode = "insecure"` because the static-key guide
requires it: a static key keeps no mutable join state, so join-state
verification fails on every rejoin otherwise. `agent-lgm` and `agent-siem` are
the same shape.

Consequences worth knowing: `recovery.limit` is **inert** in this mode, which is
why none is set rather than setting a number that implies a control that is not
applied; and static keys **cannot rotate**, so never add `rotate_after`.

## Things that will bite

- **Add the vmid to the vzdump job in the same breath as creating the host.** A
  container is not backed up until its vmid is in the job's list and nothing
  warns you. Three containers sat unbacked for days because the job still read
  an older list.
- **`sudo` is installed deliberately.** Teleport's host user creation
  hard-requires `visudo`; without it the agent logs
  `Skipping host user management ... missing required binaries: visudo` at
  **DEBUG severity only**, then every session dies with "unknown user X" no
  matter how correct the roles are.
- **Give an App-serving host both `Node` and `App` token roles.** A Node-only
  token makes the App registration fall back to the legacy join path and fail
  with a message that reads like a capability problem.
- **`template_file_id` reads back empty** after refresh, because the API does
  not report which template a container came from. `ignore_changes` on
  `operating_system` is why a plan does not propose replacing a running host.
- **Prefer `ip_address = "dhcp"` for new hosts.** Static hosts never send the
  router a DHCP request, so it has no name to register, which is why they do
  not resolve in internal DNS. Static addressing is the cause of the missing
  DNS, not a workaround for it. `dev-linux-desktop` (CT113, 2026-09-29) was the
  first host built with DHCP and resolved by name immediately. The older hosts
  are still static; add a record in `homelab/unifi/dns.tf` if one needs a name.

## Linux desktop hosts

Set `linux_desktop = {}` and add `"LinuxDesktop"` to `teleport_roles`, then
install a desktop environment and Xvfb with `provision_script`. Left at its
`null` default, nothing is rendered, so existing callers' configs are
byte-identical (proved by planning all four: `No changes`).

The service **never creates host users**: session start calls
`hostuser.Lookup(login)` and fails if the user is missing
(`lib/srv/desktop/x11/xsession.go`, 18.11.0). For per-person logins each person
SSHes to the host once, under a role with `create_host_user_mode = keep`, and
then opens the desktop as that login. So a desktop host must NOT match any role
that leaves the mode unset, or the SSH step creates nobody.
