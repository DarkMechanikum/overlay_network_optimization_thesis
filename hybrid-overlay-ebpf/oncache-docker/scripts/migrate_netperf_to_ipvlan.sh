#!/usr/bin/env bash
# Recreate netperf containers on ipvlan L3 (host-parent) networks for ONCache fast-path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

NETWORK_NAME="${IPVLAN_NETWORK_NAME:-bench-ipvlan}"
# Container subnet (do not use 10.0.2.x — Hetzner vSwitch uses those on host lo).
SUBNET="${IPVLAN_SUBNET:-10.0.3.0/24}"
GATEWAY="${IPVLAN_GATEWAY:-10.0.3.1}"
IMAGE="${NETPERF_IMAGE:-cilium/netperf}"
SERVER_IP="${IPVLAN_SERVER_IP:-10.0.3.2}"
CLIENT_IP="${IPVLAN_CLIENT_IP:-10.0.3.3}"

remote_gw() {
	local host="$1"
	remote "${host}" "ip -4 route show default 2>/dev/null | awk '{print \$3; exit}'"
}

migrate_host() {
	local host="$1"
	local parent="$2"
	local name="$3"
	local ip="$4"
	local extra="${5:-sleep infinity}"

	log "Migrating ${name} on ${host} to ${NETWORK_NAME} (${ip})"
	remote_bash "${host}" <<EOF
set -euo pipefail
if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  have=\$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "${NETWORK_NAME}")
  if [ "\${have}" != "${SUBNET}" ]; then
    docker network rm "${NETWORK_NAME}" 2>/dev/null || true
  fi
fi
if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  docker network create -d ipvlan \\
    --attachable \\
    --subnet "${SUBNET}" \\
    --gateway "${GATEWAY}" \\
    -o parent="${parent}" \\
    -o ipvlan_mode=l3 \\
    "${NETWORK_NAME}"
fi
docker rm -f "${name}" 2>/dev/null || true
docker run -d --name "${name}" --hostname "${name}" \\
  --network "${NETWORK_NAME}" --ip "${ip}" \\
  "${IMAGE}" ${extra}
docker ps --filter name="${name}"
EOF
}

migrate_host "${SERVER_HOST}" "${SERVER_NODE_IFNAME}" "${SERVER_CONTAINER}" "${SERVER_IP}" "sleep infinity"
migrate_host "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}" "${CLIENT_CONTAINER}" "${CLIENT_IP}" "sleep infinity"

remote "${SERVER_HOST}" "docker exec '${SERVER_CONTAINER}' pkill netserver 2>/dev/null || true; docker exec -d '${SERVER_CONTAINER}' netserver -D"
sleep 2

# vSwitch host IPs on lo (Hetzner cloud network); fall back to public SSH addresses.
SERVER_UNDERLAY="${SERVER_UNDERLAY:-168.119.133.106}"
CLIENT_UNDERLAY="${CLIENT_UNDERLAY:-168.119.133.107}"
export SERVER_UNDERLAY CLIENT_UNDERLAY
log "Underlay routes: ${SERVER_HOST} -> ${CLIENT_IP} via ${CLIENT_UNDERLAY}, ${CLIENT_HOST} -> ${SERVER_IP} via ${SERVER_UNDERLAY}"
if ! "${SCRIPT_DIR}/check_vswitch.sh" "${CONFIG_FILE}"; then
	log "vSwitch underlay not ready — continuing with GRE/public fallback (see check_vswitch.sh hints)"
fi
"${SCRIPT_DIR}/setup_ipvlan_routes.sh" "${CONFIG_FILE}"

if ! "${SCRIPT_DIR}/verify_ipvlan_lab.sh" "${CONFIG_FILE}"; then
	log "verify_ipvlan_lab failed — check gre-oncache routes and container default via ${IPVLAN_GATEWAY:-10.0.3.1}"
	exit 1
fi

log "Rebuild ONCache without overlay sandbox skip:"
log "  ONCACHE_OVERLAY_FLAGS='' ${SCRIPT_DIR}/build_oncache.sh ${REMOTE_ONCACHE_DIR}"
