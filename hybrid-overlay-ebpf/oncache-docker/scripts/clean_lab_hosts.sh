#!/usr/bin/env bash
# Remove thesis-lab Docker containers/networks and ipvlan route/NAT artifacts.
# Does not remove gre-oncache or vSwitch (10.0.2.x) addresses on lo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

NETWORK_OVERLAY="${OVERLAY_NETWORK:-bench-net}"
NETWORK_IPVLAN="${IPVLAN_NETWORK_NAME:-bench-ipvlan}"
SERVER_IP="${IPVLAN_SERVER_IP:-10.0.3.2}"
CLIENT_IP="${IPVLAN_CLIENT_IP:-10.0.3.3}"
IPVLAN_GW="${IPVLAN_GATEWAY:-10.0.3.1}"
GRE_IFACE="${GRE_IFACE:-gre-oncache}"

"${SCRIPT_DIR}/stop_all.sh" "${CONFIG_FILE}" || true

clean_host() {
	local host="$1"
	local node_ifname="$2"
	local local_container_ip="$3"
	local remote_container_ip="$4"

	log "Cleaning ${host} (${node_ifname})"
	remote_bash "${host}" <<REMOTE_EOF
set -euo pipefail
pkill -f docker_daemon.py 2>/dev/null || true

for c in '${SERVER_CONTAINER}' '${CLIENT_CONTAINER}'; do
  docker rm -f "\${c}" 2>/dev/null || true
done

for net in '${NETWORK_IPVLAN}' '${NETWORK_OVERLAY}'; do
  docker network rm "\${net}" 2>/dev/null || true
done

# Prune dangling ipvlan/shim links (ignore errors).
docker network prune -f 2>/dev/null || true

# Host routes / addresses added by setup_ipvlan_routes.sh
ip addr del ${IPVLAN_GW}/32 dev ${node_ifname} 2>/dev/null || true
ip addr del ${local_container_ip}/32 dev lo 2>/dev/null || true
ip route del ${local_container_ip}/32 dev ${node_ifname} scope link 2>/dev/null || true
ip route del ${remote_container_ip}/32 2>/dev/null || true

for dev in ${node_ifname} ${GRE_IFACE}; do
  iptables -t nat -D POSTROUTING -s ${local_container_ip}/32 -d ${remote_container_ip}/32 -j SNAT 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s ${local_container_ip}/32 -d ${remote_container_ip}/32 -o \${dev} -j SNAT 2>/dev/null || true
  iptables -D FORWARD -i \${dev} -o ${node_ifname} -d ${local_container_ip}/32 -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i ${node_ifname} -o \${dev} -s ${local_container_ip}/32 -j ACCEPT 2>/dev/null || true
done

rm -rf /sys/fs/bpf/tc/globals/* 2>/dev/null || true
rm -rf /tmp/oncache_mixed_netperf_* 2>/dev/null || true

echo "-- remaining thesis containers --"
docker ps -a --filter name=netperf --format '{{.Names}} {{.Status}}' || true
echo "-- remaining thesis networks --"
docker network ls --format '{{.Name}} {{.Driver}}' | grep -E 'bench-|ingress' || echo "(none)"
echo "-- routes for ${SERVER_IP}/${CLIENT_IP} --"
ip -4 route show | grep -E '${SERVER_IP}|${CLIENT_IP}|${IPVLAN_GW}' || echo "(none)"
REMOTE_EOF
}

clean_host "${SERVER_HOST}" "${SERVER_NODE_IFNAME}" "${SERVER_IP}" "${CLIENT_IP}"
clean_host "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}" "${CLIENT_IP}" "${SERVER_IP}"

if [[ "${LEAVE_SWARM:-0}" == "1" ]] || [[ "${TEARDOWN_SWARM:-0}" == "1" ]]; then
	log "Leaving Docker Swarm (removes ingress overlay, docker_gwbridge, host veth)"
	remote "${CLIENT_HOST}" "docker swarm leave 2>/dev/null || true"
	remote "${SERVER_HOST}" "docker swarm leave --force 2>/dev/null || true"
fi

for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	log "Interfaces on ${host} after cleanup:"
	remote "${host}" "ip -br link; echo; ip -br addr show scope global; echo; docker network ls 2>/dev/null || true"
done

log "Lab cleanup done on ${SERVER_HOST} and ${CLIENT_HOST} (gre-oncache and 10.0.2.x on lo left intact)"
log "Set LEAVE_SWARM=1 to drop Swarm ingress (docker_gwbridge + veth). K8s/Antrea on server1 is separate."
