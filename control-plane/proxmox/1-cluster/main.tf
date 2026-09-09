##################################################################################
# SINGLE-NODE k3s IN A PRIVILEGED LXC CONTAINER ON PROXMOX
##################################################################################
#
# Reworked from the VM version: Chris wants containers over VMs on Proxmox where
# feasible, and k3s runs fine in a *privileged* LXC on `hollowtree` (cgroup v2
# confirmed). A container also drops the cloud-init template requirement — we
# just need the Ubuntu LXC template that already lives on the node.
#
# The catch: k3s/kubelet/containerd need raw LXC knobs that the bpg/proxmox
# provider does NOT model (apparmor unconfined, cgroup2 device access, rw
# proc/sys, no dropped caps, plus /dev/kmsg). Those are applied out-of-band by
# `null_resource.lxc_raw_config` below, which SSHes the node and appends them to
# /etc/pve/lxc/<vmid>.conf. This is a known bpg limitation (the provider has no
# passthrough for arbitrary `lxc.*` keys), not a hack — see the README.
#
# ALSO applied out-of-band by that same null_resource: the CT feature flags
# (nesting, keyctl). Proxmox restricts *changing feature flags on a privileged
# container* to the real root@pam login — creating them through the bpg API
# token (authid root@pam!terraform) is refused with HTTP 403 even at privsep=0.
# So the bpg resource creates the bare privileged CT, and `pct set --features`
# (run as root@pam on the node) turns on nesting+keyctl before the restart.

locals {
  kube_host = "https://${var.container_ip}:6443"

  # SSH target = the Proxmox NODE (the box that runs `pct`), not the container.
  # Everything guest-side (raw config restart, k3s install, kubeconfig pull) is
  # driven through `pct` over this one SSH hop, using the caller's ssh-agent.
  node_ssh = "${var.proxmox_ssh_user}@${var.proxmox_ssh_host}"

  # k3s install line, run INSIDE the CT via `pct exec ... -- sh -c '<this>'`.
  # - keep servicelb (klipper): it hands the Teleport `LoadBalancer` Service the
  #   container's own IP, which is exactly what cloudflared points its origin at.
  #   This is the klipper equivalent of the EKS NLB — do NOT `--disable servicelb`.
  # - --disable traefik: we don't need an ingress controller; Teleport's proxy
  #   Service is fronted by cloudflared, not traefik.
  # - --write-kubeconfig-mode 644: so the fetch step can read k3s.yaml.
  # - --tls-san <container_ip>: so the API server cert is valid for the IP the
  #   downstream providers dial (https://<container_ip>:6443).
  k3s_env_prefix   = var.k3s_version != "" ? "INSTALL_K3S_VERSION=${var.k3s_version} " : ""
  k3s_install_cmd  = "curl -sfL https://get.k3s.io | ${local.k3s_env_prefix}INSTALL_K3S_EXEC='--disable traefik --write-kubeconfig-mode 644 --tls-san ${var.container_ip}' sh -"
  kubeconfig_local = "${path.module}/kubeconfig"
}

resource "proxmox_virtual_environment_container" "k3s" {
  node_name   = var.proxmox_node
  vm_id       = var.container_vm_id
  tags        = ["teleport", "k3s", "terraform"]
  description = "Single-node k3s hosting the Teleport control plane (presales replica). Privileged LXC, managed by terraform."

  # Privileged CT: required so the k3s workload can do the privileged things
  # kubelet/containerd need (mounts, sysctls, device cgroups). Paired with the
  # raw lxc.conf tweaks in null_resource.lxc_raw_config.
  unprivileged = false

  started       = true
  start_on_boot = true

  # Features (nesting/keyctl) are set out-of-band by null_resource.lxc_raw_config
  # via `pct set` (Proxmox only lets the real root@pam login change feature flags
  # on a privileged CT — the bpg API token is refused with 403). bpg would
  # otherwise see the out-of-band features as drift and try to REMOVE them (also
  # 403), so we tell it to ignore that field entirely.
  lifecycle {
    ignore_changes = [features]
  }

  operating_system {
    template_file_id = var.os_template_file_id
    type             = "ubuntu"
  }

  cpu {
    cores = var.container_cpu_cores
  }

  memory {
    dedicated = var.container_memory_mb
    swap      = var.container_swap_mb
  }

  # Rootfs on the ember ZFS pool.
  disk {
    datastore_id = var.datastore_id
    size         = var.container_disk_gb
  }

  # NOTE: `features { nesting keyctl }` is deliberately NOT set here. Proxmox
  # only lets the real root@pam login change feature flags on a *privileged* CT;
  # the bpg API token (root@pam!terraform) is refused with HTTP 403 even at
  # privsep=0. So they're applied via `pct set --features` in
  # null_resource.lxc_raw_config below (which runs as root@pam on the node).
  # - nesting: lets containerd/k3s run nested containers inside this CT.
  # - keyctl:  kubelet/containerd use the kernel keyring (Proxmox otherwise
  #            seccomp-blocks the keyctl syscall — a raw lxc.* line can't fix
  #            that, only the Proxmox feature flag adjusts the seccomp profile).

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  initialization {
    hostname = var.container_hostname

    ip_config {
      ipv4 {
        address = "${var.container_ip}/${var.container_netmask}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    # OPTIONAL. Primary access is `pct exec`/`pct console` from the node, so the
    # block only appears if a key or password was supplied (for direct debugging).
    dynamic "user_account" {
      for_each = (trimspace(var.container_ssh_public_key) != "" || var.container_root_password != null) ? [1] : []
      content {
        keys     = trimspace(var.container_ssh_public_key) != "" ? [trimspace(var.container_ssh_public_key)] : null
        password = var.container_root_password
      }
    }
  }
}

##################################################################################
# k3s-in-LXC RAW CONFIG (bpg limitation workaround)
##################################################################################
#
# The bpg/proxmox provider does not expose raw `lxc.*` container keys, so we
# append them to /etc/pve/lxc/<vmid>.conf over SSH and restart the CT. All the
# terraform-known values (node SSH target, vmid) are substituted at render time;
# the rest is literal bash run on the node. The append is marker-guarded so a
# re-apply doesn't duplicate the block. Runs once per container (trigger = vmid).
resource "null_resource" "lxc_raw_config" {
  depends_on = [proxmox_virtual_environment_container.k3s]

  triggers = {
    vmid = proxmox_virtual_environment_container.k3s.vm_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # Flush-left heredoc on purpose: the nested remote heredocs need their
    # delimiters (REMOTE / LXCCONF) at column 0 for the remote shell to see them.
    command = <<EOT
set -euo pipefail
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${local.node_ssh}" bash -s <<'REMOTE'
set -euo pipefail
vmid="${proxmox_virtual_environment_container.k3s.vm_id}"
conf="/etc/pve/lxc/$vmid.conf"
# Feature flags: root@pam-only on a privileged CT (the bpg token gets 403), so
# set them here where we ARE root@pam on the node. Idempotent. Takes effect on
# the restart below.
pct set "$vmid" --features nesting=1,keyctl=1
# IMPORTANT: no `#` comment lines inside the heredoc below. Proxmox parses `#`
# lines in /etc/pve/lxc/<vmid>.conf as the container *description*, which then
# fights bpg's own description field. So we write ONLY real `lxc.*` keys; the
# rationale for each lives here, in the terraform source:
#   lxc.apparmor.profile: unconfined -> default profile blocks kubelet/containerd mounts+sysctls; k3s won't start under it
#   lxc.cap.drop: (empty)            -> keep all caps; kubelet needs CAP_SYS_ADMIN et al.
#   lxc.cgroup2.devices.allow: a     -> containerd/kubelet create device cgroups, need host devices (loop, /dev/kmsg)
#   lxc.mount.auto: proc:rw sys:rw   -> kubelet writes sysctls, needs rw /proc & /sys
# Marker for idempotency = a real key line (not a `#` comment, which we no longer write).
if ! grep -q '^lxc.apparmor.profile: unconfined' "$conf"; then
cat >> "$conf" <<'LXCCONF'
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cgroup2.devices.allow: a
lxc.mount.auto: proc:rw sys:rw
LXCCONF
fi
# Cold restart so the new apparmor profile / mount.auto / features are re-read
# (Proxmox 9 has no `pct restart`; a warm reboot may not re-apply lxc.* keys).
pct stop "$vmid" || true
for i in $(seq 1 15); do
  [ "$(pct status "$vmid" 2>/dev/null)" = "status: stopped" ] && break
  sleep 1
done
pct start "$vmid"
REMOTE
echo "lxc.conf tweaks applied + CT restarted"
EOT
  }
}

##################################################################################
# k3s INSTALL (inside the CT, via `pct exec` from the node)
##################################################################################
#
# Runs after the raw-config restart so kubelet has the caps/cgroups/mounts it
# needs. Ensures /dev/kmsg exists (k3s/kubelet reads it; a privileged CT doesn't
# get one by default — symlink it to /dev/console), installs curl, runs the k3s
# installer, then polls until the node reports Ready.
resource "null_resource" "k3s_install" {
  depends_on = [null_resource.lxc_raw_config]

  triggers = {
    vmid        = proxmox_virtual_environment_container.k3s.vm_id
    install_cmd = local.k3s_install_cmd
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
set -euo pipefail
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${local.node_ssh}" bash -s <<'REMOTE'
set -euo pipefail
vmid="${proxmox_virtual_environment_container.k3s.vm_id}"
# Wait for the CT to accept `pct exec` — `pct restart` (raw-config step) returns
# before the container's init has fully settled.
for i in $(seq 1 20); do
  if pct exec "$vmid" -- true 2>/dev/null; then break; fi
  echo "waiting for CT $vmid to accept pct exec ($i/20)..."
  sleep 3
done
# k3s/kubelet needs /dev/kmsg; a privileged CT has none — point it at the console.
pct exec "$vmid" -- sh -c '[ -e /dev/kmsg ] || ln -s /dev/console /dev/kmsg'
# curl + CA certs for the k3s installer.
pct exec "$vmid" -- sh -c 'command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl ca-certificates; }'
# install k3s (servicelb kept — that IP is the cloudflared origin).
pct exec "$vmid" -- sh -c "${local.k3s_install_cmd}"
# poll until the single node is Ready.
for i in $(seq 1 30); do
  if pct exec "$vmid" -- /usr/local/bin/k3s kubectl get node 2>/dev/null | grep -qw Ready; then
    echo "k3s node Ready"
    exit 0
  fi
  echo "waiting for k3s node Ready ($i/30)..."
  sleep 10
done
echo "ERROR: k3s node did not reach Ready in time" >&2
exit 1
REMOTE
EOT
  }
}

##################################################################################
# KUBECONFIG HAND-OFF (1-cluster -> 2/3/4)
##################################################################################
#
# SAME output contract as the VM version — this just changes HOW the file is
# pulled (node `pct exec cat` instead of a direct SSH into the guest). We read
# /etc/rancher/k3s/k3s.yaml out of the CT, rewrite the server address from
# 127.0.0.1 to the container IP, and write it to 1-cluster/kubeconfig. outputs.tf
# then yamldecodes the CA/cert/key and exports them; 2/3/4-* consume those via
# terraform_remote_state — unchanged. See README.
resource "null_resource" "fetch_kubeconfig" {
  depends_on = [null_resource.k3s_install]

  triggers = {
    vmid      = proxmox_virtual_environment_container.k3s.vm_id
    kube_host = local.kube_host
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
set -euo pipefail
dest="${local.kubeconfig_local}"
for i in $(seq 1 30); do
  if out=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${local.node_ssh}" \
       "pct exec ${proxmox_virtual_environment_container.k3s.vm_id} -- cat /etc/rancher/k3s/k3s.yaml" 2>/dev/null) \
     && [ -n "$out" ]; then
    printf '%s\n' "$out" | sed "s#https://127.0.0.1:6443#${local.kube_host}#g" > "$dest"
    echo "kubeconfig written to $dest"
    exit 0
  fi
  echo "waiting for k3s kubeconfig ($i/30)..."
  sleep 10
done
echo "ERROR: timed out reading k3s kubeconfig via ${local.node_ssh}" >&2
exit 1
EOT
  }
}

# Read the fetched kubeconfig back into terraform so outputs.tf can parse the
# CA/cert/key out of it. depends_on defers the read until after the fetch.
data "local_file" "kubeconfig" {
  depends_on = [null_resource.fetch_kubeconfig]
  filename   = local.kubeconfig_local
}
