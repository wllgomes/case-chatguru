#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="case-chatguru"

echo "Removendo cluster kind '$CLUSTER_NAME'..."
kind delete cluster --name "$CLUSTER_NAME"