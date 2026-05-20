#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

install_on_host() {
	local host="$1"
	log "Installing Kubernetes/Antrea/ONCache build dependencies on ${host}"
	remote_bash "${host}" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
	apt-transport-https ca-certificates curl gnupg lsb-release \
	build-essential clang llvm libelf-dev libpcap-dev bc rsync \
	cmake python3 python3-yaml git sysstat stress-ng \
	containerd cri-tools || true

mkdir -p /etc/containerd
if [[ ! -f /etc/containerd/config.toml ]]; then
	containerd config default >/etc/containerd/config.toml
fi
# kubeadm + recent kubelet works best with systemd cgroups.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
systemctl daemon-reload
systemctl enable --now containerd

# Kubernetes 1.28 packages (Ubuntu 22.04/20.04 compatible)
if ! command -v kubeadm >/dev/null 2>&1; then
	curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null || true
	echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' \
		> /etc/apt/sources.list.d/kubernetes.list
	apt-get update -qq
	apt-get install -y -qq kubelet kubeadm kubectl || true
	apt-mark hold kubelet kubeadm kubectl || true
fi

command -v bpftool >/dev/null || apt-get install -y -qq linux-tools-common linux-tools-generic || true
EOF
}

for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	install_on_host "${host}"
done

log "Dependency install finished"
