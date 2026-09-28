# estate-agent — /etc/teleport.yaml for the two hand-built estate agents.
#
# WHY THIS EXISTS. On 2026-09-27 retagging lgm and siem from `env: home` to
# `env: prod` meant four `sed` edits over SSH and two service restarts, none of
# it reviewable as a diff, while CT105 and CT106 needed nothing because
# modules/self-database-lxc templates their whole config. Same day, planning
# the heronwright cutover surfaced the same gap again: those two agents need a
# new `proxy_server` by hand where the database pair rewrites itself.
#
# The pattern is the repo's own. modules/ssh-node/userdata.tpl interpolates
# `${env}` and `${team}` into ssh_service.labels; modules/app-grafana does the
# same alongside an app_service block. This module is those two, minus cloud
# userdata, because these hosts are an LXC and a WSL distro rather than EC2
# instances.
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   * It does not install Teleport. Both agents are installed and joined.
#   * It does not create or read the bound_keypair static key. That stays a
#     one-time `tbot keypair create --static` on the host, and the private half
#     never enters terraform state. See the "generate on the HOST" default in
#     ~/github/CLAUDE.md.
#   * It does not manage the provision token. That is
#     control-plane/proxmox/3-rbac/agents.tf, which holds the PUBLIC key.

locals {
  rendered = templatefile("${path.module}/teleport.yaml.tpl", {
    nodename        = var.nodename
    proxy_address   = var.proxy_address
    token_name      = var.token_name
    static_key_path = var.static_key_path
    labels          = var.labels
    log_severity    = var.log_severity
    apps            = var.apps
  })

  b64 = base64encode(local.rendered)

  # `try()` does NOT catch a null -- null is a valid value, not an error, so
  # try(var.delivery.vm_id, 0) returns null and the interpolation below fails
  # with "Invalid template interpolation value". It fails even in ssh_stdin
  # mode, where vm_id is legitimately unset, because Terraform evaluates every
  # local regardless of which one the resource ends up selecting. coalesce is
  # the operator that actually handles null.
  vm_id = coalesce(var.delivery.vm_id, 0)

  restart = var.restart_agent ? "systemctl restart teleport" : "echo 'restart_agent = false; leaving the running agent alone'"

  # A BACKUP BEFORE EVERY WRITE, on the host, with the config hash in the name.
  # Cheap, and the only way back if a render is wrong on a host whose SSH you
  # may have just broken by restarting its Teleport agent.
  backup_suffix = substr(sha256(local.rendered), 0, 8)

  proxmox_lxc_command = <<-EOT
    set -euo pipefail
    printf '%s' '${local.b64}' \
      | ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 '${var.delivery.ssh_target}' \
          "set -e
           B=/tmp/teleport-${var.nodename}.yaml
           cat > \$B.b64
           base64 -d \$B.b64 > \$B
           pct exec ${local.vm_id} -- sh -c 'test ! -f /etc/teleport.yaml || cp /etc/teleport.yaml /etc/teleport.yaml.bak-${local.backup_suffix}'
           pct push ${local.vm_id} \$B /etc/teleport.yaml --perms 644
           pct exec ${local.vm_id} -- ${local.restart}
           rm -f \$B \$B.b64"
  EOT

  # The payload rides INSIDE the script here rather than on the argv, because
  # this path goes through cmd.exe on the way to WSL and long argument lines
  # fail there.
  ssh_stdin_command = <<-EOT
    set -euo pipefail
    cat <<'ESTATE_AGENT_EOF' \
      | ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o RequestTTY=no '${var.delivery.ssh_target}' '${var.delivery.remote_shell}'
    set -e
    test ! -f /etc/teleport.yaml || cp /etc/teleport.yaml /etc/teleport.yaml.bak-${local.backup_suffix}
    printf '%s' '${local.b64}' | base64 -d > /etc/teleport.yaml
    chmod 644 /etc/teleport.yaml
    ${local.restart}
    ESTATE_AGENT_EOF
  EOT
}

# `terraform_data`, NOT `null_resource`.
#
# They do the same job, but null_resource comes from the hashicorp/null
# PROVIDER, and terraform_data is built into Terraform itself (1.4+; this repo
# requires >= 1.6). Pulling in a provider to do nothing is a dependency for no
# benefit. null_resource is not deprecated, but terraform_data is the
# documented replacement and the right default for new code.
#
# modules/self-database-lxc still uses null_resource. That is where this
# module's shape came from and it predates the check — worth converting when
# that module is next touched, not as a campaign, since the conversion is a
# destroy-and-create of the provisioner.
#
# The field is `triggers_replace`, not `triggers`.
resource "terraform_data" "config" {
  triggers_replace = {
    # Hash rather than the config itself, so state stays readable and a diff
    # says "the config changed" instead of printing the file twice.
    config   = sha256(local.rendered)
    nodename = var.nodename
    restart  = tostring(var.restart_agent)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = var.delivery.mode == "proxmox_lxc" ? local.proxmox_lxc_command : local.ssh_stdin_command
  }
}
