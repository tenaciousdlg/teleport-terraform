#!/bin/bash
set -euxo pipefail
hostnamectl set-hostname teleport-gcp-cli
curl -fsS --connect-timeout 10 --retry 10 --retry-connrefused --retry-delay 6 "https://${proxy_address}/scripts/install.sh" | bash
cat <<EOT > /etc/teleport.yaml
version: v3
teleport:
  data_dir: /var/lib/teleport
  proxy_server: ${proxy_address}:443
  join_params:
    method: gcp
    token_name: ${token_name}
app_service:
  enabled: true
  apps:
  - name: google-cloud-cli
    cloud: GCP
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
