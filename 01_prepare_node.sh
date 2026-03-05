#!/usr/bin/env bash
set -euo pipefail

K8S_CHANNEL="v1.30"               # OK, but you can also use v1.29 for slightly lighter defaults
ENABLE_UFW="${ENABLE_UFW:-yes}"
ADMIN_CIDR="${ADMIN_CIDR:-0.0.0.0/0}"  # set to YOUR_IP/32 for safety

echo "[INFO] Updating OS..."
sudo apt-get update -y
sudo apt-get upgrade -y

echo "[INFO] Disabling swap..."
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/ s/^/#/' /etc/fstab

echo "[INFO] Kernel modules + sysctl..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "[INFO] Installing containerd..."
sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https
sudo apt-get install -y containerd

echo "[INFO] Configuring containerd..."
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "[INFO] Installing Kubernetes packages..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_CHANNEL}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_CHANNEL}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet

# (Optional but helpful on 1 vCPU) Reduce kubelet verbosity to reduce overhead
sudo mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-extra-args.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--v=2"
EOF
sudo systemctl daemon-reload
sudo systemctl restart kubelet || true

if [[ "${ENABLE_UFW}" == "yes" ]]; then
  echo "[INFO] Configuring UFW (lab-safe)..."
  sudo apt-get install -y ufw

  sudo ufw --force reset
  sudo ufw default deny incoming
  sudo ufw default allow outgoing

  sudo ufw allow 22/tcp

  # Restrict API server + etcd to your admin IP if you set ADMIN_CIDR=YOUR_IP/32
  sudo ufw allow from "${ADMIN_CIDR}" to any port 6443 proto tcp
  sudo ufw allow from "${ADMIN_CIDR}" to any port 2379:2380 proto tcp

  # kubelet API and overlay transport (needed between nodes)
  sudo ufw allow 10250/tcp
  sudo ufw allow 8472/udp   # Flannel VXLAN

  sudo ufw --force enable
  sudo ufw status verbose
fi

echo "[INFO] Done. Reboot recommended: sudo reboot"
