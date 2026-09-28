# estate-agents — `/etc/teleport.yaml` for lgm and siem

The two hand-built agents, now templated. CT105 and CT106 already got this from
`modules/self-database-lxc`, which is why they needed nothing during the
2026-09-27 `env: prod` retag while these two took four `sed` calls over SSH.

| agent | host | delivery |
|---|---|---|
| `lgm` | WSL Ubuntu on a Windows box | `ssh_stdin` → `wsl -d Ubuntu -u root -e bash` |
| `siem` | CT104 on hollowtree | `proxmox_lxc` → `pct push` + `pct exec` |

## Adoption, not construction

Both agents were already installed, joined and running. Before the first apply
each rendered config was diffed against the live file **and parsed as YAML on
both sides**: semantically identical. The text differed only in comments and in
label order, because Terraform iterates a map in lexical key order and YAML
mappings are unordered.

That distinction is the point. Diffing the text would have shown a dozen
differences and told you nothing about whether the agent would behave the same.
Compare meaning, not bytes, when adopting something already running.

Every write takes a backup on the host first, named with the config hash:
`/etc/teleport.yaml.bak-<8 hex>`.

## No providers

`terraform providers` reports only `terraform.io/builtin/terraform`. This layer
is `templatefile` plus `terraform_data`, so it needs **no Teleport credential
and no `tfenv` pre-flight** to plan or apply. The provision tokens
these configs name live in `control-plane/proxmox/3-rbac/agents.tf`, which does
need one.

`terraform_data`, not `null_resource`: they do the same job, but null_resource
comes from the `hashicorp/null` provider and `terraform_data` is built into
Terraform (1.4+, and this repo requires >= 1.6). The field is
`triggers_replace`. `modules/self-database-lxc` still uses null_resource, which
is where this module's shape came from — worth converting when that module is
next touched.

## The cutover

`var.proxy_address` is the switch. Change it once and both agents are rewritten
and restarted by an apply.

**It does not clear the data_dirs, and you must.** `/var/lib/teleport` holds
certs issued by the OLD cluster's CA, and no config change evicts them. lgm
needed exactly that on the CT102 to CT103 cutover. After changing
`proxy_address`:

```sh
# siem
ssh root@hollowtree 'pct exec 104 -- systemctl stop teleport
                     pct exec 104 -- rm -rf /var/lib/teleport
                     pct exec 104 -- systemctl start teleport'
# lgm
ssh -o RequestTTY=no lgm-win 'wsl -d Ubuntu -u root -e bash' <<'EOF'
systemctl stop teleport && rm -rf /var/lib/teleport && systemctl start teleport
EOF
```

The bound_keypair **static keys do not change**. A bound_keypair binds to
cluster name + CA, so the new cluster's token registers the same public key
(already in `3-rbac/agents.tf` as `local.agent_public_keys`) and the agent
re-binds on its first join. No `tbot keypair create` unless a host is itself
rebuilt or its key is lost.

## What this does not manage

- **Teleport installation.** Both agents are installed.
- **The bound_keypair static key.** One-time `tbot keypair create --static` on
  the host; the private half never enters Terraform state.
- **The provision token.** `control-plane/proxmox/3-rbac/agents.tf`.
- **CT104's other contents** — Loki, Grafana, Alloy, the event handler. Those
  are partly captured in `~/github/homelab/ct104-siem`. The container itself is
  declared in `~/github/homelab/proxmox`.
