#!/usr/bin/env bash
# Destructive cleanup to get a reproducible Kubernetes+Antrea benchmark baseline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

log "Stopping ONCache daemons and TC programs"
"${SCRIPT_DIR}/stop_oncache.sh" "${CONFIG_FILE}" || true

cleanup_host() {
	local host="$1"
	local ifname="$2"
	log "Cleaning host ${host} (${ifname})"
	remote_bash "${host}" <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

pkill -9 -f 'python3.*daemon.py' 2>/dev/null || true

if command -v kubeadm >/dev/null 2>&1; then
  kubeadm reset -f 2>/dev/null || true
fi
systemctl stop kubelet 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true

rm -rf /etc/cni/net.d/* /var/lib/cni/* /var/lib/kubelet/* 2>/dev/null || true
rm -rf /root/.kube /home/*/.kube 2>/dev/null || true

if command -v crictl >/dev/null 2>&1; then
  crictl rm -fa >/dev/null 2>&1 || true
  crictl rmi --prune >/dev/null 2>&1 || true
fi

if [[ -x '${REMOTE_ONCACHE_DIR}/user_prog/tc_prog_loader' ]]; then
  '${REMOTE_ONCACHE_DIR}/user_prog/tc_prog_loader' --dev '${ifname}' --remove --egress 2>/dev/null || true
  '${REMOTE_ONCACHE_DIR}/user_prog/tc_prog_loader' --dev '${ifname}' --remove 2>/dev/null || true
fi

tc qdisc del dev '${ifname}' clsact 2>/dev/null || true
rm -rf /sys/fs/bpf/tc/globals/* 2>/dev/null || true
rm -rf /tmp/oncache_* /tmp/k8s_oncache_* 2>/dev/null || true

echo "-- host cleanup summary --"
hostname
ip -br link
ip -br addr
EOF
}

cleanup_host "${SERVER_HOST}" "${SERVER_NODE_IFNAME}"
cleanup_host "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}"

log "Clearing cluster-side objects from control-plane host"
remote "${MASTER_HOST}" "kubectl delete pod '${SERVER_POD}' '${CLIENT_POD}' -n '${NAMESPACE}' --ignore-not-found=true --wait=true" || true

log "Host cleanup complete"
