#!/usr/bin/env bash
# Provision a two-node kubeadm cluster with Antrea on server1 (master) + server2 (worker).
# WARNING: destructive — resets kubeadm state on these hosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

resolve_ip() {
	local host="$1"
	local override="$2"
	if [[ -n "${override}" ]]; then
		printf '%s' "${override}"
		return
	fi
	remote "${host}" "ip -4 -o route get 1.1.1.1 | awk '{print \$7; exit}'"
}

SERVER_IP="$(resolve_ip "${SERVER_HOST}" "${SERVER_NODE_IP:-}")"
CLIENT_IP="$(resolve_ip "${CLIENT_HOST}" "${CLIENT_NODE_IP:-}")"
log "Cluster node IPs: ${SERVER_NODE_NAME}=${SERVER_IP} ${CLIENT_NODE_NAME}=${CLIENT_IP}"

log "Initializing control plane on ${MASTER_HOST}"
remote_bash "${MASTER_HOST}" <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
swapoff -a || true
sed -i '/ swap / s/^/#/' /etc/fstab || true
modprobe br_netfilter overlay || true
cat >/etc/modules-load.d/k8s.conf <<MODS
br_netfilter
overlay
MODS
cat >/etc/sysctl.d/k8s.conf <<SYS
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
SYS
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/k8s.conf

mkdir -p /etc/containerd
if [[ ! -f /etc/containerd/config.toml ]]; then
  containerd config default >/etc/containerd/config.toml
fi
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd
echo "KUBELET_EXTRA_ARGS=--node-ip=${SERVER_IP}" >/etc/default/kubelet
systemctl daemon-reload
systemctl restart kubelet || true

kubeadm reset -f 2>/dev/null || true
rm -f \$HOME/.kube/config
kubeadm init \\
	--apiserver-advertise-address "${SERVER_IP}" \\
	--pod-network-cidr "${POD_NETWORK_CIDR}" \\
	--node-name "${SERVER_NODE_NAME}"

mkdir -p \$HOME/.kube
cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config
chown "\$(id -u):\$(id -g)" \$HOME/.kube/config
kubectl taint nodes "${SERVER_NODE_NAME}" node-role.kubernetes.io/control-plane- 2>/dev/null || \\
	kubectl taint nodes "${SERVER_NODE_NAME}" node-role.kubernetes.io/master- 2>/dev/null || true
EOF

JOIN_CMD="$(remote "${MASTER_HOST}" "kubeadm token create --print-join-command 2>/dev/null") --node-name ${CLIENT_NODE_NAME}"
log "Join command: ${JOIN_CMD}"

log "Joining worker ${CLIENT_HOST}"
remote_bash "${CLIENT_HOST}" <<EOF
set -euo pipefail
swapoff -a || true
mkdir -p /etc/containerd
if [[ ! -f /etc/containerd/config.toml ]]; then
  containerd config default >/etc/containerd/config.toml
fi
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd
echo "KUBELET_EXTRA_ARGS=--node-ip=${CLIENT_IP}" >/etc/default/kubelet
systemctl daemon-reload
systemctl restart kubelet || true
kubeadm reset -f 2>/dev/null || true
rm -f \$HOME/.kube/config
${JOIN_CMD}
mkdir -p \$HOME/.kube
EOF

# Copy kubeconfig to worker (from orchestrator machine).
scp ${SSH_OPTS} "${MASTER_HOST}:.kube/config" "${CLIENT_HOST}:.kube/config"
remote "${CLIENT_HOST}" "chown \$(id -u):\$(id -g) \$HOME/.kube/config"

log "Installing Antrea ${ANTREA_VERSION}"
remote "${MASTER_HOST}" "kubectl apply -f https://github.com/antrea-io/antrea/releases/download/${ANTREA_VERSION}/antrea.yml"

log "Waiting for nodes Ready"
remote "${MASTER_HOST}" "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
remote "${MASTER_HOST}" "kubectl get nodes -o wide"
log "Kubernetes + Antrea provision complete"
