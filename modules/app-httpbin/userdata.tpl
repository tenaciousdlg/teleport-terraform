#!/bin/bash
set -euxo pipefail
# Set hostname
hostnamectl set-hostname "${name}"
# Install dependencies
sudo dnf install -y docker jq
systemctl enable docker
systemctl start docker
# Run httpbin container
docker run -d \
  --name=httpbin \
  -p 80:80 \
  --restart=always \
  kennethreitz/httpbin
# Install Teleport
curl -fsS --connect-timeout 10 --retry 10 --retry-connrefused --retry-delay 6 "https://${proxy_address}/scripts/install.sh" | bash

# Configure Teleport
cat <<EOF_TEL > /etc/teleport.yaml
version: v3
teleport:
  data_dir: "/var/lib/teleport"
  join_params:
    method: iam
    token_name: ${token}
  proxy_server: ${proxy_address}:443
  log:
    output: stderr
    severity: INFO
    format:
      output: text
app_service:
  enabled: "yes"
  resources:
    - labels:
        "teleport.dev/app": "httpbin"
        "env": "${env}"
        "team": "${team}"
ssh_service:
  enabled: "no"
auth_service:
  enabled: "no"
proxy_service:
  enabled: "no"
EOF_TEL

# Write token to disk
# Enable and start Teleport
systemctl enable teleport
systemctl restart teleport
