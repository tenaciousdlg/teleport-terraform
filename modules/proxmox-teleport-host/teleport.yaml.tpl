# /etc/teleport.yaml — MANAGED BY TERRAFORM (modules/proxmox-teleport-host).
# Hand edits are reverted on the next apply. That is the point: the estate lost
# an evening to hand-placed configs that kept a dead cluster's hostname after a
# migration, while `systemctl is-active` reported them fine.
version: v3
teleport:
  nodename: ${name}
  proxy_server: ${proxy_address}:443
  join_params:
    method: bound_keypair
    token_name: ${token_name}
    bound_keypair:
      # STATIC key, generated on this host by the bootstrap script. The path
      # must match --static-key-path exactly or the join fails looking for a
      # key that is sitting elsewhere on the same disk.
      static_key_path: ${static_key_path}
  # Diagnostic endpoint, so this host's metrics can be scraped like the control
  # plane's. Loopback is fine here: nothing scrapes agent metrics yet, and
  # opening it on the LAN before there is a collector would be exposure with no
  # consumer.
  diag_addr: 127.0.0.1:3000
  log:
    severity: INFO
    output: stderr

auth_service:
  enabled: false
proxy_service:
  enabled: false

ssh_service:
  enabled: true
  labels:
%{ for k, v in labels ~}
    ${k}: ${v}
%{ endfor ~}

%{ if length(apps) > 0 || length(mcp_apps) > 0 ~}
app_service:
  enabled: true
  apps:
%{ for a in apps ~}
    - name: ${a.name}
      uri: ${a.uri}
      labels:
%{ for k, v in labels ~}
        ${k}: ${v}
%{ endfor ~}
%{ endfor ~}
%{ for m in mcp_apps ~}
    # stdio MCP server. No `uri`: Teleport LAUNCHES this command on demand and
    # proxies stdio. run_as_host_user is required and the app will not start
    # without it.
    - name: ${m.name}
      mcp:
        command: ${m.command}
        args: ${jsonencode(m.args)}
        run_as_host_user: ${m.run_as_host_user}
      labels:
%{ for k, v in labels ~}
        ${k}: ${v}
%{ endfor ~}
%{ endfor ~}
%{ else ~}
app_service:
  enabled: false
%{ endif ~}

%{ if linux_desktop != null ~}
# Linux desktop access. Teleport starts Xvfb per session and launches the
# desktop inside it, so this host needs a DE and Xvfb installed, and every
# login must already exist on the host (the service never creates users).
linux_desktop_service:
  enabled: true
  labels:
%{ for k, v in labels ~}
    ${k}: ${v}
%{ endfor ~}
%{ if linux_desktop.xsessions_included != "" || linux_desktop.xsessions_excluded != "" ~}
  xsessions:
%{ if linux_desktop.xsessions_included != "" ~}
    included: "${linux_desktop.xsessions_included}"
%{ endif ~}
%{ if linux_desktop.xsessions_excluded != "" ~}
    excluded: "${linux_desktop.xsessions_excluded}"
%{ endif ~}
%{ endif ~}

%{ endif ~}
db_service:
  enabled: false
kubernetes_service:
  enabled: false
windows_desktop_service:
  enabled: false
