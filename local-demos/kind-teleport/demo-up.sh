#!/usr/bin/env bash
# Spins up a local multi-node kind cluster and joins it to Teleport as a
# kube_service, for on-the-spot K8s access demos with no cloud dependency.
#
# Required env vars:
#   TELEPORT_PROXY_ADDR   e.g. presales.teleportdemo.com:443
#   TELEPORT_JOIN_TOKEN   from: tctl tokens add --type=kube --format=text
#
# Usage: ./demo-up.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-teleport-demo}"
PROXY_ADDR="${TELEPORT_PROXY_ADDR:?Set TELEPORT_PROXY_ADDR, e.g. presales.teleportdemo.com:443}"
JOIN_TOKEN="${TELEPORT_JOIN_TOKEN:?Set TELEPORT_JOIN_TOKEN — create one with: tctl tokens add --type=kube --format=text}"

echo "==> Creating kind cluster '$CLUSTER_NAME' (1 control-plane + 2 workers)"
kind create cluster --name "$CLUSTER_NAME" --config "$DIR/kind-teleport-demo.yaml"

echo "==> Installing Teleport kube agent"
helm repo add teleport https://charts.releases.teleport.dev --force-update
helm repo update
helm upgrade --install teleport-agent teleport/teleport-kube-agent \
  --create-namespace --namespace teleport-agent \
  --set roles=kube \
  --set proxyAddr="$PROXY_ADDR" \
  --set authToken="$JOIN_TOKEN" \
  --set kubeClusterName="$CLUSTER_NAME" \
  --wait

echo "==> Done. Verify with: tsh kube ls"
echo "    Tear down with: ./demo-down.sh"
