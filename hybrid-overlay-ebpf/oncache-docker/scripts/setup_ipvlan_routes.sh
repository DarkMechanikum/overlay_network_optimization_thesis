#!/usr/bin/env bash
# Host sysctl + routes for cross-host ipvlan L3 (bench-ipvlan).
#
# Ipvlan L3 delivers to containers only when traffic ingresses on the parent NIC.
# GRE return traffic must therefore either be avoided (vSwitch/private underlay) or
# SNAT container flows to the host public address so replies hit the parent stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

SERVER_IP="${IPVLAN_SERVER_IP:-10.0.3.2}"
CLIENT_IP="${IPVLAN_CLIENT_IP:-10.0.3.3}"
SERVER_UNDERLAY="${SERVER_UNDERLAY:-168.119.133.106}"
CLIENT_UNDERLAY="${CLIENT_UNDERLAY:-168.119.133.107}"
GRE_IFACE="${GRE_IFACE:-gre-oncache}"
IPVLAN_GW="${IPVLAN_GATEWAY:-10.0.3.1}"
# auto | vswitch | gre | public
IPVLAN_UNDERLAY_MODE="${IPVLAN_UNDERLAY_MODE:-auto}"

host_public_src() {
	local host="$1"
	remote "${host}" "ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print \$7; exit}'"
}

peer_reachable() {
	local from_host="$1"
	local peer_addr="$2"
	remote "${from_host}" "ping -c1 -W2 '${peer_addr}' >/dev/null 2>&1"
}

gre_tunnel_addrs() {
	local host="$1"
	remote "${host}" "bash -s" -- "${GRE_IFACE}" <<'REMOTE'
set -euo pipefail
iface="$1"
if ! ip link show "${iface}" >/dev/null 2>&1; then
  exit 1
fi
ip -4 -o addr show dev "${iface}" | awk '{print $4}' | cut -d/ -f1
REMOTE
}

resolve_path() {
	local host="$1"
	local node_ifname="$2"
	local remote_container_ip="$3"
	local peer_host="$4"
	local peer_lo="$5"
	local local_lo="$6"
	local mode="${IPVLAN_UNDERLAY_MODE}"

	if [[ "${mode}" == "auto" || "${mode}" == "vswitch" ]]; then
		if peer_reachable "${host}" "${peer_lo}"; then
			printf '%s|%s|%s|vswitch\n' "${node_ifname}" "${peer_lo}" "${local_lo}"
			return 0
		fi
		if [[ "${mode}" == "vswitch" ]]; then
			echo "vSwitch peer ${peer_lo} not reachable from ${host}" >&2
			exit 1
		fi
	fi

	if [[ "${mode}" == "auto" || "${mode}" == "gre" ]]; then
		local gre_local gre_peer
		if gre_local="$(gre_tunnel_addrs "${host}" 2>/dev/null)" && [[ -n "${gre_local}" ]]; then
			gre_peer="$(gre_tunnel_addrs "${peer_host}" 2>/dev/null || true)"
			if [[ -n "${gre_peer}" ]]; then
				printf '%s|%s|%s|gre\n' "${GRE_IFACE}" "${gre_peer}" "$(host_public_src "${host}")"
				return 0
			fi
		fi
		if [[ "${mode}" == "gre" ]]; then
			echo "GRE tunnel ${GRE_IFACE} missing on ${host} or ${peer_host}" >&2
			exit 1
		fi
	fi

	local pub
	pub="$(host_public_src "${peer_host}")"
	printf '%s|%s|%s|public\n' "${node_ifname}" "${pub}" "$(host_public_src "${host}")"
}

fix_container_ipvlan_routes() {
	local host="$1"
	local container="$2"
	local subnet_cidr="${IPVLAN_SUBNET:-10.0.3.0/24}"
	remote_bash "${host}" <<REMOTE_EOF
set -euo pipefail
run_sudo() {
  if [ "\$(id -u)" -eq 0 ]; then "\$@"; else sudo "\$@"; fi
}
pid=\$(docker inspect -f '{{.State.Pid}}' '${container}')
run_sudo nsenter -t "\${pid}" -n ip route del ${subnet_cidr} dev eth0 2>/dev/null || true
run_sudo nsenter -t "\${pid}" -n ip route replace default via ${IPVLAN_GW} dev eth0 onlink
REMOTE_EOF
}

setup_host() {
	local host="$1"
	local node_ifname="$2"
	local remote_ip="$3"
	local peer_host="$4"
	local peer_lo="$5"
	local local_lo="$6"

	local local_container_ip
	if [[ "${host}" == "${SERVER_HOST}" ]]; then
		local_container_ip="${SERVER_IP}"
	else
		local_container_ip="${CLIENT_IP}"
	fi

	local path dev via snat_src path_kind
	path="$(resolve_path "${host}" "${node_ifname}" "${remote_ip}" "${peer_host}" "${peer_lo}" "${local_lo}")"
	IFS='|' read -r dev via snat_src path_kind <<<"${path}"

	log "Routes on ${host}: ${remote_ip} via ${via} dev ${dev} (${path_kind}) snat ${snat_src} local ${local_container_ip}"

	remote_bash "${host}" <<REMOTE_EOF
set -euo pipefail
run_sudo() {
  if [ "\$(id -u)" -eq 0 ]; then "\$@"; else sudo "\$@"; fi
}
run_sudo sysctl -w net.ipv4.ip_forward=1
run_sudo sysctl -w net.ipv4.conf.all.rp_filter=0
run_sudo sysctl -w net.ipv4.conf.default.rp_filter=0
run_sudo sysctl -w net.ipv4.conf.all.forwarding=1
set_conf_sysctl() {
  local key="\$1" val="\$2"
  local proc="/proc/sys/net/ipv4/conf/${node_ifname}/\${key}"
  if [ -f "\${proc}" ]; then
    echo "\${val}" > "\${proc}"
  else
    run_sudo sysctl -w "net.ipv4.conf.${node_ifname}.\${key}=\${val}"
  fi
}
set_conf_sysctl proxy_arp 1
set_conf_sysctl accept_local 1
if ip link show '${GRE_IFACE}' >/dev/null 2>&1; then
  run_sudo sysctl -w net.ipv4.conf.${GRE_IFACE}.rp_filter=0
fi

# Gateway for container default routes (ipvlan L3).
run_sudo ip addr replace ${IPVLAN_GW}/32 dev ${node_ifname} 2>/dev/null || true

# Local container IP must not be on lo (breaks return delivery).
run_sudo ip addr del ${local_container_ip}/32 dev lo 2>/dev/null || true
run_sudo ip route replace ${local_container_ip}/32 dev ${node_ifname} scope link

if [ "${path_kind}" = "public" ]; then
  run_sudo ip route replace ${remote_ip}/32 via ${via} dev ${dev} onlink
else
  run_sudo ip route replace ${remote_ip}/32 via ${via} dev ${dev}
fi

run_sudo iptables -t nat -D POSTROUTING -s ${local_container_ip}/32 -d ${remote_ip}/32 -j SNAT --to-source ${snat_src} 2>/dev/null || true
if [ "${path_kind}" = "gre" ] || [ "${path_kind}" = "public" ]; then
  run_sudo iptables -t nat -C POSTROUTING -s ${local_container_ip}/32 -d ${remote_ip}/32 -o ${dev} -j SNAT --to-source ${snat_src} 2>/dev/null || \
    run_sudo iptables -t nat -A POSTROUTING -s ${local_container_ip}/32 -d ${remote_ip}/32 -o ${dev} -j SNAT --to-source ${snat_src}
elif [ "${path_kind}" = "vswitch" ]; then
  run_sudo iptables -t nat -D POSTROUTING -s ${local_container_ip}/32 -d ${remote_ip}/32 -o ${dev} -j SNAT --to-source ${snat_src} 2>/dev/null || true
fi

run_sudo iptables -D FORWARD -i ${dev} -o ${node_ifname} -d ${local_container_ip}/32 -j ACCEPT 2>/dev/null || true
run_sudo iptables -D FORWARD -i ${node_ifname} -o ${dev} -s ${local_container_ip}/32 -j ACCEPT 2>/dev/null || true
run_sudo iptables -C FORWARD -i ${dev} -o ${node_ifname} -d ${local_container_ip}/32 -j ACCEPT 2>/dev/null || \
  run_sudo iptables -I FORWARD 1 -i ${dev} -o ${node_ifname} -d ${local_container_ip}/32 -j ACCEPT
run_sudo iptables -C FORWARD -i ${node_ifname} -o ${dev} -s ${local_container_ip}/32 -j ACCEPT 2>/dev/null || \
  run_sudo iptables -I FORWARD 1 -i ${node_ifname} -o ${dev} -s ${local_container_ip}/32 -j ACCEPT

ip -4 route show | grep -E '${SERVER_IP}|${CLIENT_IP}|${via}|${dev}' || true
REMOTE_EOF
}

setup_host "${SERVER_HOST}" "${SERVER_NODE_IFNAME}" "${CLIENT_IP}" "${CLIENT_HOST}" "${CLIENT_UNDERLAY}" "${SERVER_UNDERLAY}"
setup_host "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}" "${SERVER_IP}" "${SERVER_HOST}" "${SERVER_UNDERLAY}" "${CLIENT_UNDERLAY}"

fix_container_ipvlan_routes "${SERVER_HOST}" "${SERVER_CONTAINER}"
fix_container_ipvlan_routes "${CLIENT_HOST}" "${CLIENT_CONTAINER}"
