#!/bin/bash
set -euxo pipefail
hostnamectl set-hostname teleport-azure-cli
curl -fsS --connect-timeout 10 --retry 10 --retry-connrefused --retry-delay 6 "https://${proxy_address}/scripts/install.sh" | bash
cat <<EOT > /etc/teleport.yaml
version: v3
teleport:
  data_dir: /var/lib/teleport
  proxy_server: ${proxy_address}:443
  join_params:
    method: azure
    token_name: ${token_name}
    azure:
      client_id: ${client_id}
app_service:
  enabled: true
  apps:
  - name: azure-cli
    cloud: Azure
    labels:
      env: ${env}
      team: ${team}
auth_service:
  enabled: "no"
ssh_service:
  enabled: "no"
proxy_service:
  enabled: "no"
EOT
systemctl enable teleport
systemctl restart teleport
