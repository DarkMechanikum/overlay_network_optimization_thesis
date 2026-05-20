#!/usr/bin/env bash
# Recreate netperf containers on the Swarm overlay (bench-net).
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

"${SCRIPT_DIR}/stop_all.sh" "${CONFIG_FILE}" || true

restore_host() {
	local host="$1"
	local name="$2"
	local ip="$3"
	log "Restoring ${name} on ${host} (${ip}) on ${NETWORK}"
	remote_bash "${host}" <<EOF
set -euo pipefail
docker rm -f "${name}" 2>/dev/null || true
docker run -d --name "${name}" --hostname "${name}" \\
  --network "${NETWORK}" --ip "${ip}" \\
  "${IMAGE}" sleep infinity
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${name}"
EOF
}

restore_host "${SERVER_HOST}" "${SERVER_CONTAINER}" "${SERVER_IP}"
restore_host "${CLIENT_HOST}" "${CLIENT_CONTAINER}" "${CLIENT_IP}"
remote "${SERVER_HOST}" "docker exec -d '${SERVER_CONTAINER}' netserver -D"
sleep 2
remote "${CLIENT_HOST}" "docker exec '${CLIENT_CONTAINER}' ping -c 2 -W 2 '${SERVER_IP}'"
