#!/usr/bin/env bash
# Strip Swarm, Kubernetes/Antrea, and lab Docker state; keep Docker CE + host NICs for ipvlan benchmark.
# Preserves: lo, enp*, gre-oncache (if present), vSwitch 10.0.2.x on lo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

teardown_k8s() {
	local host="$1"
	local is_master="${2:-0}"

	log "Tearing down Kubernetes on ${host}"
	remote_bash "${host}" <<REMOTE_EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

systemctl stop kubelet 2>/dev/null || true

if [[ "${is_master}" == "1" ]] && [[ -f /etc/kubernetes/admin.conf ]]; then
  kubectl --kubeconfig=/etc/kubernetes/admin.conf delete pod --all-namespaces --all \
    --force --grace-period=0 2>/dev/null || true
fi

kubeadm reset -f 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true

rm -rf /etc/cni/net.d/* /var/lib/cni/* /var/lib/kubelet/* 2>/dev/null || true
rm -rf "\${HOME}/.kube" /root/.kube 2>/dev/null || true

if command -v ovs-vsctl >/dev/null 2>&1 || [[ -d /etc/openvswitch ]]; then
  systemctl start openvswitch-switch 2>/dev/null || true
  ovs-vsctl --if-exists del-br br-int 2>/dev/null || true
  ovs-vsctl --if-exists del-br antrea-gw0 2>/dev/null || true
  ovs-vsctl show 2>/dev/null | awk '/^Bridge/{print \$2}' | tr -d '\"' | while read -r br; do
    ovs-vsctl --if-exists del-br "\${br}" 2>/dev/null || true
  done
  systemctl stop openvswitch-switch 2>/dev/null || true
  systemctl disable openvswitch-switch 2>/dev/null || true
fi

while read -r iface; do
  case "\${iface}" in
    coredns--*|antrea-*|genev_sys*|ovs-system|flannel.*|cali*|vxlan.calico*)
      ip link del "\${iface}" 2>/dev/null || true
      ;;
  esac
done < <(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//')

ip link del antrea-egress0 2>/dev/null || true

systemctl restart docker 2>/dev/null || true
docker system prune -f 2>/dev/null || true
REMOTE_EOF
}

log "=== Phase 1: lab containers, routes, ONCache ==="
LEAVE_SWARM=0 "${SCRIPT_DIR}/clean_lab_hosts.sh" "${CONFIG_FILE}"

log "=== Phase 2: Kubernetes (worker ${CLIENT_HOST} first) ==="
if remote "${CLIENT_HOST}" "command -v kubeadm >/dev/null 2>&1"; then
	teardown_k8s "${CLIENT_HOST}" 0
else
	log "No kubeadm on ${CLIENT_HOST}, skipping K8s teardown"
fi

if remote "${SERVER_HOST}" "command -v kubeadm >/dev/null 2>&1"; then
	teardown_k8s "${SERVER_HOST}" 1
else
	log "No kubeadm on ${SERVER_HOST}, skipping K8s teardown"
fi

log "=== Phase 3: Docker Swarm (not needed for ipvlan benchmark) ==="
remote "${CLIENT_HOST}" "docker swarm leave 2>/dev/null || true"
remote "${SERVER_HOST}" "docker swarm leave --force 2>/dev/null || true"

log "=== Phase 4: prune unused Docker networks ==="
for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	remote "${host}" "docker network prune -f 2>/dev/null || true"
done

log "=== Final interface summary ==="
"${SCRIPT_DIR}/list_host_interfaces.sh" "${CONFIG_FILE}"

log "Teardown complete. Hosts should have: lo, enp*, docker0, optional gre-oncache + 10.0.2.x on lo."
