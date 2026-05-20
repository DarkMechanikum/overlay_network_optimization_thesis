#!/usr/bin/env bash
# Verify cross-host ipvlan container connectivity before ONCache benchmarks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

SERVER_IP="${IPVLAN_SERVER_IP:-10.0.3.2}"
CLIENT_IP="${IPVLAN_CLIENT_IP:-10.0.3.3}"
NETSERVER_PORT="${NETSERVER_PORT:-12865}"

log "Ping ${SERVER_IP} from ${CLIENT_CONTAINER} on ${CLIENT_HOST}"
remote "${CLIENT_HOST}" "docker exec '${CLIENT_CONTAINER}' ping -c 3 -W 3 '${SERVER_IP}'"

log "TCP_RR probe from client to server"
remote "${CLIENT_HOST}" \
	"docker exec '${CLIENT_CONTAINER}' netperf -H '${SERVER_IP}' -p '${NETSERVER_PORT}' -t TCP_RR -l 3 -- -r 64,64"

log "Ipvlan lab connectivity OK (${CLIENT_IP} -> ${SERVER_IP})"
