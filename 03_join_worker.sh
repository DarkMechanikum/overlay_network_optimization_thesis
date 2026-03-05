#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"sudo kubeadm join <cp-ip>:6443 --token ... --discovery-token-ca-cert-hash sha256:...\""
  exit 1
fi

JOIN_CMD="$*"

echo "[INFO] Joining cluster..."
# shellcheck disable=SC2086
${JOIN_CMD}

echo "[INFO] Done. Verify from control plane:"
echo "  kubectl get nodes -o wide"
