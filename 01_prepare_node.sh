#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (edit if needed)
# =========================
K8S_CHANNEL="v1.30"  # Kubernetes stable channel
# Restrict API server access to your IP (recommended). Example: "203.0.113.50/32"
ADMIN_CIDR="${ADMIN_CIDR:-0.0.0.0/0}"   # export ADMIN_CIDR=YOUR_IP/32 before running for safety
ENABLE_UFW="${ENABLE_UFW:-yes}"

echo "[INFO] Updating OS..."
sudo apt-get update -y
sudo apt-get upgrade -y

echo "[INFO] Disabling swap (required by kubelet)..."
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/ s/^/#/' /etc/fstab

echo "[INFO] Loading kernel modules..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

echo "[INFO] Applying sysctl settings..."
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "[INFO] Installing containerd..."
sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https
sudo apt-get install -y containerd

echo "[INFO] Configuring containerd (SystemdCgroup=true)..."
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "[INFO] Installing kubeadm/kubelet/kubectl..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_CHANNEL}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_CHANNEL}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet

if [[ "${ENABLE_UFW}" == "yes" ]]; then
  echo "[INFO] Setting up UFW firewall rules for Kubernetes..."
  sudo apt-get install -y ufw

  sudo ufw --force reset
  sudo ufw default deny incoming
  sudo ufw default allow outgoing

  # SSH
  sudo ufw allow 22/tcp

  # Kubernetes API server (control plane only in practice, but safe to allow on all nodes)
  # Restrict to your ADMIN_CIDR if provided.
  sudo ufw allow from "${ADMIN_CIDR}" to any port 6443 proto tcp

  # etcd (control plane only; keep restricted)
  sudo ufw allow from "${ADMIN_CIDR}" to any port 2379:2380 proto tcp

  # kubelet API (node-to-node; you can keep open to cluster nodes later)
  sudo ufw allow 10250/tcp

  # Flannel VXLAN uses UDP 8472 between nodes
  sudo ufw allow 8472/udp

  # NodePort range (optional; enable only if you use NodePort services)
  # sudo ufw allow 30000:32767/tcp
  # sudo ufw allow 30000:32767/udp

  sudo ufw --force enable
  sudo ufw status verbose
fi

echo "[INFO] Done. Reboot recommended."
echo "Run: sudo reboot"
