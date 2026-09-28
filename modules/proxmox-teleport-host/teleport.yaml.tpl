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

%{ if length(apps) > 0 ~}
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
%{ else ~}
app_service:
  enabled: false
%{ endif ~}

db_service:
  enabled: false
kubernetes_service:
  enabled: false
windows_desktop_service:
  enabled: false
