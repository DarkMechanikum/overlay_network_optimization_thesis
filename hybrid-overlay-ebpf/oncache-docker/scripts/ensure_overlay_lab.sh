#!/usr/bin/env bash
# Ensure Docker Swarm + bench-net overlay and netperf containers (thesis lab).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

NETWORK="${OVERLAY_NETWORK:-bench-net}"
SERVER_IP="${OVERLAY_SERVER_IP:-10.0.1.2}"
CLIENT_IP="${OVERLAY_CLIENT_IP:-10.0.1.4}"
IMAGE="${NETPERF_IMAGE:-cilium/netperf}"

swarm_state() {
	local host="$1"
	remote "${host}" "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null" | tr -d '[:space:]'
}

ensure_docker() {
	local host="$1"
	remote "${host}" "systemctl unmask docker.service docker.socket 2>/dev/null || true"
	remote "${host}" "systemctl enable --now docker 2>/dev/null || true"
	remote "${host}" "docker info >/dev/null"
}

ensure_docker "${SERVER_HOST}"
ensure_docker "${CLIENT_HOST}"

if [[ "$(swarm_state "${SERVER_HOST}")" != "active" ]]; then
	log "Initializing Docker Swarm on ${SERVER_HOST}"
	remote "${SERVER_HOST}" "docker swarm init --advertise-addr '${SERVER_UNDERLAY:-$(remote "${SERVER_HOST}" "hostname -I | awk '{print \$1}'")}'" || \
		remote "${SERVER_HOST}" "docker swarm init" || true
fi

if [[ "$(swarm_state "${CLIENT_HOST}")" != "active" ]]; then
	log "Joining ${CLIENT_HOST} to Swarm"
	token="" addr=""
	token="$(remote "${SERVER_HOST}" "docker swarm join-token worker -q")"
	addr="$(remote "${SERVER_HOST}" "docker info --format '{{.Swarm.NodeAddr}}'")"
	remote "${CLIENT_HOST}" "docker swarm join --token '${token}' '${addr}:2377'" || true
fi

log "Ensuring overlay network ${NETWORK}"
remote "${SERVER_HOST}" "
set -euo pipefail
if ! docker network inspect '${NETWORK}' >/dev/null 2>&1; then
  docker network create -d overlay --attachable '${NETWORK}'
fi
"

need_restore=0
for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	name="" ip=""
	if [[ "${host}" == "${SERVER_HOST}" ]]; then
		name="${SERVER_CONTAINER}"
		ip="${SERVER_IP}"
	else
		name="${CLIENT_CONTAINER}"
		ip="${CLIENT_IP}"
	fi
	if ! remote "${host}" "docker inspect '${name}' >/dev/null 2>&1"; then
		need_restore=1
		continue
	fi
	actual=""
	actual="$(remote "${host}" "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' '${name}'" | tr -d '[:space:]')"
	if [[ "${actual}" != "${ip}" ]]; then
		log "Container ${name} on ${host} has IP ${actual}, expected ${ip}; recreating"
		need_restore=1
	fi
done

if [[ "${need_restore}" == "1" ]]; then
	"${SCRIPT_DIR}/restore_overlay_netperf.sh" "${CONFIG_FILE}"
else
	remote "${SERVER_HOST}" "docker exec '${SERVER_CONTAINER}' pkill netserver 2>/dev/null || true"
	remote "${SERVER_HOST}" "docker exec -d '${SERVER_CONTAINER}' netserver -D" || \
		"${SCRIPT_DIR}/restore_overlay_netperf.sh" "${CONFIG_FILE}"
	sleep 1
fi

if ! remote "${CLIENT_HOST}" "docker exec '${CLIENT_CONTAINER}' ping -c 1 -W 4 '${SERVER_IP}'" >/dev/null 2>&1; then
	log "Cross-host overlay ping failed; recreating containers"
	"${SCRIPT_DIR}/restore_overlay_netperf.sh" "${CONFIG_FILE}"
else
	log "Overlay lab ready: ${SERVER_CONTAINER}@${SERVER_IP} <-> ${CLIENT_CONTAINER}@${CLIENT_IP} on ${NETWORK}"
fi
