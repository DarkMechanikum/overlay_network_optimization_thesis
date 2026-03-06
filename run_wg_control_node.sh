#!/usr/bin/env bash
set -euo pipefail

CP1_WG_IP="10.200.0.1"
POD_CIDR="10.244.0.0/16"

echo "[cp1] Starting WireGuard..."
sudo systemctl enable --now wg-quick@wg0
sudo wg show

echo "[cp1] Checking wg interface..."
ip -4 addr show wg0

echo "[cp1] OPTIONAL: reset and re-init Kubernetes to use WireGuard IP."
echo "       If this is a fresh cluster or you want to rebuild cleanly, proceed."
echo

echo "[cp1] Resetting kubeadm state..."
sudo kubeadm reset -f || true
sudo rm -rf "$HOME/.kube" /etc/cni/net.d /var/lib/cni
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo systemctl restart containerd

echo "[cp1] Initializing control plane on ${CP1_WG_IP}..."
sudo kubeadm init \
  --apiserver-advertise-address="${CP1_WG_IP}" \
  --apiserver-cert-extra-sans="${CP1_WG_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --ignore-preflight-errors=NumCPU

echo "[cp1] Setting up kubectl..."
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

echo "[cp1] Installing Flannel VXLAN..."
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo "[cp1] Waiting for Flannel..."
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=300s || true

echo "[cp1] Allow scheduling on control plane (useful on tiny nodes)..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo
echo "[cp1] Worker join command (use this on w1 and w2):"
echo "------------------------------------------------------------"
kubeadm token create --print-join-command
echo "------------------------------------------------------------"
echo
echo "[cp1] Verify:"
echo "  kubectl get nodes -o wide"
