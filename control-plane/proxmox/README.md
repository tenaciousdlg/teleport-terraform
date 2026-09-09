# Teleport control plane on Proxmox + k3s

A single-node **k3s-on-Proxmox** replica of the presales EKS control plane.
Same Teleport Helm deployment and the same
operator-driven RBAC — just running in a **privileged LXC container** on the
`hollowtree` homelab node instead of AWS, fronted by a Cloudflare tunnel instead
of an NLB + Route53.

Intended cluster address: **`teleport.chrisdlg.com`**.

## Layer map

| Layer | EKS original | Proxmox replica |
|-------|--------------|-----------------|
| `1-cluster`  | EKS + VPC + node groups | One **privileged LXC** on `hollowtree`, single-node **k3s** via `pct exec` |
| `2-teleport` | Helm chart, `chartMode=aws` (DynamoDB/S3/NLB) | Helm chart, `chartMode=standalone` (PVC), self-signed origin cert |
| `3-rbac`     | operator CRs (roles, AMRs, access lists, kube-RBAC, demo apps) | **reused** as-is; SAML connectors carried but gated off |
| `4-plugins`  | Slack access-request plugin (tbot k8s-join) | **reused** as-is |

`5-access-graph` and `6-cost` are **out of scope** for now (no AWS = no
DynamoDB/RDS TAG backend, no AWS cost scheduler). Access Graph plumbing is left
in `2-teleport` behind `access_graph_enabled` (default `false`) so the auth
config still diffs cleanly against eks.

## Deltas from the EKS layers

- **Privileged LXC, not a VM.** `1-cluster` runs k3s inside a *privileged* LXC
  container on `hollowtree` (Chris prefers containers over VMs on Proxmox where
  feasible; cgroup v2 on this host makes k3s-in-LXC viable). No cloud-init VM
  template is needed — just the Ubuntu 24.04 LXC template already on the node.
  k3s/kubelet/containerd need raw LXC knobs the `bpg/proxmox` provider does
  **not** model (it has no passthrough for arbitrary `lxc.*` keys), so a
  `null_resource` SSHes the node and appends them to `/etc/pve/lxc/<vmid>.conf`,
  then `pct restart`s the CT. This is a known bpg limitation, not a hack. The
  keys and why:
  - `lxc.apparmor.profile: unconfined` — the default profile blocks the
    mounts/sysctls kubelet & containerd perform; k3s won't start under it.
  - `lxc.cap.drop:` (empty) — drop no capabilities; kubelet needs `CAP_SYS_ADMIN` et al.
  - `lxc.cgroup2.devices.allow: a` — cgroup2 device access for containerd/kubelet.
  - `lxc.mount.auto: proc:rw sys:rw` — kubelet writes sysctls / reads-writes `/proc` & `/sys`.

  The container is also created with `features { nesting, keyctl }` and, at
  install time, `/dev/kmsg` is provided (`ln -s /dev/console /dev/kmsg`, which
  k3s/kubelet requires and a privileged CT lacks by default). k3s itself is
  installed **inside** the CT via `ssh <node> pct exec <vmid> -- …`, so we never
  SSH the container directly.
- **Standalone chart mode.** No DynamoDB backend, no S3 session recordings. The
  auth backend + recordings live on a PVC on k3s's default `local-path`
  StorageClass. No AWS IAM / IRSA / DynamoDB / S3 resources at all — `iam.tf` and
  `infra.tf` are gone.
- **Self-signed origin cert + Cloudflare edge.** cert-manager stays, but only the
  `selfsigned-issuer` ClusterIssuer remains (the LetsEncrypt/Route53 ACME issuer
  is removed). The `teleport-tls` Certificate is issued self-signed. Cloudflare's
  edge presents the real public cert for `teleport.chrisdlg.com`; the cloudflared
  tunnel dials the origin with `no_tls_verify=true`, so a self-signed cert on the
  origin `:443` is sufficient.
- **No Route53 / DNS in terraform.** DNS + ingress are external and already
  applied in `~/github/cloudflare-infra` (`hollowtree-tunnel.tf`): the tunnel
  routes `teleport.chrisdlg.com` → the k3s LoadBalancer Service on `:443`
  (`no_tls_verify=true`, no Access app in front so `tsh`'s ALPN upgrade works).
- **Single node.** `proxy.highAvailability.replicaCount = 1`, no
  `topologySpreadConstraints`, no `externalTrafficPolicy=Local` (that fixed an
  NLB client-IP problem that does not exist here). klipper (servicelb) is kept —
  it hands the Teleport `LoadBalancer` Service the container's own IP.
- **k3s flags:** `--disable traefik --write-kubeconfig-mode 644 --tls-san <container_ip>`.
  servicelb is deliberately **kept** (that is what gives the Service its IP).

## Kubeconfig hand-off (1-cluster → 2/3/4)

Chosen approach: **terraform_remote_state (local)**, matching how the EKS layers
consumed `eks/1-cluster`.

`1-cluster` provisions the CT + k3s, then a `local-exec` SSHes to the **Proxmox
node** and reads `/etc/rancher/k3s/k3s.yaml` out of the container with
`pct exec <vmid> -- cat …`, rewrites the server address from `127.0.0.1` to the
container IP, and writes `1-cluster/kubeconfig` (gitignored). That file is parsed
with `yamldecode` into structured outputs — `kube_host`,
`cluster_ca_certificate`, `client_certificate`, `client_key` (the **same output
contract** as the VM version; only the fetch mechanism changed, so `2/3/4-*` are
untouched). `2/3/4-*` read those via `data.terraform_remote_state.cluster` (local
backend → `../1-cluster/terraform.tfstate`) and wire the kubernetes/helm/kubectl
providers with **explicit client-cert auth** (no `exec` plugin — k3s issues the
admin cert, there is no cloud IdP token to fetch).

The fetch needs SSH reachability from the machine running terraform to the
Proxmox **node** (`proxmox_ssh_host`, default `192.168.1.10`, via your ssh-agent
— the same hop the provider already uses). If that isn't available, run
`terraform output -raw fetch_kubeconfig_command` from `1-cluster`, execute the
one-liner by hand to produce `1-cluster/kubeconfig`, then re-apply `1-cluster` so
the outputs populate.

## Prerequisites

1. **Proxmox API token** on `hollowtree` (e.g. `terraform@pve!tf=...`). Export as
   `PROXMOX_VE_ENDPOINT` / `PROXMOX_VE_API_TOKEN` (or `TF_VAR_proxmox_*`). Never
   commit it.
2. **SSH to the Proxmox node** (`root@192.168.1.10` by default, via your
   ssh-agent — `ssh { agent = true }`). Used both by the provider and by the
   `1-cluster` `null_resource`s that (a) append the raw `lxc.*` keys to
   `/etc/pve/lxc/<vmid>.conf` and (b) install k3s inside the CT via `pct exec`.
   Override with `TF_VAR_proxmox_ssh_host` / `TF_VAR_proxmox_ssh_user`.
3. **Ubuntu 24.04 LXC template** present on `hollowtree` — the default
   `local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst` (already there).
   No cloud-init VM template and **no `snippets` datastore** are needed for a CT.
4. **`license.pem`** already lives at `control-plane/license.pem`
   (`../../license.pem` from `2-teleport`, same depth as the eks tree).
5. **Cloudflare route already applied** in `~/github/cloudflare-infra`:
   `teleport.chrisdlg.com` → the k3s LB Service IP on `:443`.

The k3s-in-LXC `lxc.conf` tweaks (apparmor unconfined, no dropped caps, cgroup2
device access, rw proc/sys) are applied automatically by `1-cluster` — see the
first bullet under **Deltas** for the exact keys and why each is needed.

## Apply order

```
cd 1-cluster && terraform init && terraform apply   # LXC CT + k3s + kubeconfig outputs
cd ../2-teleport && terraform init && terraform apply # Helm (standalone) + cert
cd ../3-rbac  && terraform init && terraform apply    # roles / AMRs / access lists / kube-RBAC / demo apps
cd ../4-plugins && terraform init && terraform apply  # Slack access-request plugin
```

Each layer has its own **local** backend (`terraform.tfstate` in-directory) and a
`terraform.tfvars.example`. This is a homelab — no S3, no state locking.

## Known follow-ups

- **cloudflared origin repoint.** The tunnel currently points
  `teleport.chrisdlg.com` at `192.168.1.45` (the live **CT102** origin). This new
  CT comes up on a **fresh** address — `container_ip` defaults to `192.168.1.50`
  (free) — so it can be built and validated **without disturbing** the live .45
  origin. Once the replica is validated, repoint the origin `.45` → `.50` in
  `cloudflare-infra/hollowtree-tunnel.tf`, re-apply that repo, then retire CT102.
  (If you give the CT a different IP, use that instead.)
- **SSO connector rewiring (Phase 2).** `3-rbac` carries the `okta` / `okta-preview`
  SAML connectors but they are **off by default** (`okta_metadata_url=""`,
  `enable_okta_preview=false`). They still reference the presales Okta apps —
  create NEW Okta apps bound to `teleport.chrisdlg.com` and set the metadata URLs
  before enabling. Phase 1 is **local auth**; the roles/AMRs/access-lists/kube-RBAC
  all apply without SSO. SCIM (`4-plugins/scim.tf`) is likewise a Phase-2 manual
  bootstrap.
- **5-access-graph** (and any cost tooling) not ported.
- The `local-path` PVC is single-node and not backed up — fine for a demo replica;
  don't treat session recordings here as durable.
