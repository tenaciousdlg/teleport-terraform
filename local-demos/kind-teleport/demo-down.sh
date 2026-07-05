#!/usr/bin/env bash
# Tears down the kind cluster created by demo-up.sh.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-teleport-demo}"
kind delete cluster --name "$CLUSTER_NAME"
