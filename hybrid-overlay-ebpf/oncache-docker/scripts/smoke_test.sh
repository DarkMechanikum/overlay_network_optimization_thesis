#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

RESULT_DIR="${SETUP_ROOT}/results/smoke_$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${RESULT_DIR}"

resolve_container_ip() {
	local host="$1"
	local container="$2"
	local override="$3"
	if [[ -n "${override}" ]]; then
		printf '%s' "${override}"
		return
	fi
	remote "${host}" "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' '${container}'"
}

SERVER_IP="$(resolve_container_ip "${SERVER_HOST}" "${SERVER_CONTAINER}" "${SERVER_CONTAINER_IP}")"
CLIENT_IP="$(resolve_container_ip "${CLIENT_HOST}" "${CLIENT_CONTAINER}" "${CLIENT_CONTAINER_IP}")"

log "Server container ${SERVER_CONTAINER} on ${SERVER_HOST}: ${SERVER_IP}"
log "Client container ${CLIENT_CONTAINER} on ${CLIENT_HOST}: ${CLIENT_IP}"

log "Starting netserver in ${SERVER_CONTAINER}"
remote "${SERVER_HOST}" "docker exec '${SERVER_CONTAINER}' pkill netserver 2>/dev/null || true"
remote "${SERVER_HOST}" "docker exec -d '${SERVER_CONTAINER}' netserver -D"
sleep 2

log "Running TCP_RR smoke test from ${CLIENT_CONTAINER} to ${SERVER_IP}"
remote "${CLIENT_HOST}" "docker exec '${CLIENT_CONTAINER}' netperf -H '${SERVER_IP}' -t TCP_RR -l 10 -- -r 64,64" \
	| tee "${RESULT_DIR}/tcp_rr.txt"

if grep -q "per sec" "${RESULT_DIR}/tcp_rr.txt"; then
	log "Smoke test passed"
	exit 0
fi

log "Smoke test failed"
exit 1
