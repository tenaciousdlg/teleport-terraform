# estate-agents — /etc/teleport.yaml for lgm and siem, under Terraform.
#
# These are the two agents that were hand-edited. CT105 and CT106 already get
# their config from modules/self-database-lxc, which is why they needed nothing
# during the 2026-09-27 `env: prod` retag while these two took four `sed` calls
# over SSH.
#
# ADOPTION, NOT CONSTRUCTION. Both agents are installed, joined and running.
# Before the first apply, the rendered output of each was diffed against the
# live file and parsed as YAML on both sides: **semantically identical**. The
# text differs only in comments and in label ORDER, because Terraform iterates
# a map in lexical key order and YAML mappings are unordered. Compare meaning,
# not text, when adopting something already running.
#
# NO TELEPORT PROVIDER HERE, and that is worth keeping. This layer is
# templatefile + null_resource, so it needs no `tfenv` pre-flight and
# no bot credential to plan or apply. The provision tokens these configs name
# live in control-plane/proxmox/3-rbac/agents.tf, which does need one.
#
# THE CUTOVER USE CASE. When the cluster moves to heronwright, `proxy_address`
# below changes once and both agents are rewritten and restarted by an apply.
# The data_dir still has to be wiped by hand, because it holds certs issued by
# the OLD cluster's CA and no config change evicts them — see the README.

module "lgm" {
  source = "../../modules/estate-agent"

  nodename      = "lgm"
  proxy_address = var.proxy_address
  token_name    = "agent-lgm"

  labels = {
    env  = "prod"
    team = "platform"
    role = "inference"
    # lgm is the only agent not on Proxmox. Recorded as a label so `tsh ls`
    # explains the odd one out without anyone opening this file.
    platform = "wsl-ubuntu"
  }

  apps = [{
    name   = "ollama"
    uri    = "http://127.0.0.1:11434"
    labels = { env = "prod", team = "platform", role = "inference" }
    comment = join("\n", [
      "Ollama has NO auth of its own -- Teleport RBAC is the only thing in front",
      "of it. Reach it with:  tsh proxy app ollama --port 11434",
      "The agent runs inside WSL, so it reaches loopback locally and no inbound",
      "firewall path to this box is needed.",
    ])
  }]

  # WSL, so there is no Proxmox API and no `pct`. The payload goes over stdin
  # to a root shell inside the distro. `ssh lgm` would land as `dlg` via a
  # RemoteCommand in ssh_config, where there is no passwordless sudo; `-u root`
  # gives root outright without sudo involved.
  restart_agent = var.restart_agents

  delivery = {
    mode         = "ssh_stdin"
    ssh_target   = var.lgm_ssh_target
    remote_shell = "wsl -d Ubuntu -u root -e bash"
  }
}

module "siem" {
  source = "../../modules/estate-agent"

  nodename      = "siem"
  proxy_address = var.proxy_address
  token_name    = "agent-siem"

  labels = {
    env  = "prod"
    team = "platform"
    role = "observability"
  }

  apps = [{
    name            = "grafana"
    uri             = "http://127.0.0.1:3000"
    labels          = { env = "prod", team = "platform", role = "observability" }
    rewrite_headers = ["Authorization: Bearer {{internal.jwt}}"]
    comment = join("\n", [
      "Grafana authenticates from the Teleport-signed JWT, so it has no",
      "password of its own to leak or rotate. Teleport injects the token,",
      "Grafana verifies it against the cluster JWKS, and the Teleport role",
      "decides whether you are an Admin or a Viewer.",
      "  tsh proxy app grafana --port 3000",
    ])
  }]

  restart_agent = var.restart_agents

  delivery = {
    mode       = "proxmox_lxc"
    ssh_target = var.proxmox_ssh
    vm_id      = 104
  }
}
