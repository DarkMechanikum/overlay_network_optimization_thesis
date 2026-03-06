#!/usr/bin/env bash
set -euo pipefail

CP1_WG_IP="10.200.0.1"

if [[ $# -lt 1 ]]; then
  echo "Usage:"
  echo "  $0 sudo kubeadm join 10.200.0.1:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
  exit 1
fi

JOIN_CMD="$*"

echo "[worker] Starting WireGuard..."
sudo systemctl enable --now wg-quick@wg0
sudo wg show

echo "[worker] Verifying connectivity to control plane WireGuard IP (${CP1_WG_IP})..."
ping -c 3 "${CP1_WG_IP}"

echo "[worker] Resetting kubeadm state..."
sudo kubeadm reset -f || true
sudo rm -rf /etc/cni/net.d /var/lib/cni
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo systemctl restart containerd

echo "[worker] Joining cluster..."
# shellcheck disable=SC2086
${JOIN_CMD}

echo "[worker] Done. Verify on cp1:"
echo "  kubectl get nodes -o wide"
