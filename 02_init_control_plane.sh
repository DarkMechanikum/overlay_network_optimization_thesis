#!/usr/bin/env bash
set -euo pipefail

CONTROL_PLANE_IP="45.38.228.63"
POD_CIDR="10.244.0.0/16"

echo "[INFO] Initializing control plane on 1 vCPU (NumCPU preflight ignored)..."
sudo kubeadm init \
  --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
  --apiserver-cert-extra-sans="${CONTROL_PLANE_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --ignore-preflight-errors=NumCPU

echo "[INFO] Setting up kubectl..."
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

echo "[INFO] Installing Flannel VXLAN..."
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo "[INFO] Waiting for Flannel..."
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=300s || true

echo "[INFO] Allow scheduling on control plane (useful on 1 vCPU nodes)..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo
echo "[INFO] Join command for workers:"
echo "------------------------------------------------------------"
kubeadm token create --print-join-command
echo "------------------------------------------------------------"
echo
echo "[INFO] Verify:"
echo "  kubectl get nodes -o wide"
