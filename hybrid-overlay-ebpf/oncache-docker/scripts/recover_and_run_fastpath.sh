#!/usr/bin/env bash
# Run from the dev machine once server1/server2 are reachable again.
# If the custom kernel fails to boot, use the Hetzner console and select
# "Ubuntu, with Linux 5.15.0-139-generic", then fix/reinstall the rpeer kernel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

wait_host() {
	local host="$1"
	local tries="${2:-120}"
	for ((i = 1; i <= tries; i++)); do
		if remote "${host}" "true" 2>/dev/null; then
			log "${host} is up"
			return 0
		fi
		sleep 10
	done
	log "ERROR: ${host} did not become reachable"
	return 1
}

log "Waiting for lab hosts..."
wait_host "${SERVER_HOST}"
wait_host "${CLIENT_HOST}"

for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	rel="$(remote "${host}" "uname -r")"
	log "${host}: kernel ${rel}"
	remote "${host}" "bash '${REMOTE_SETUP_DIR}/scripts/verify_rpeer_helper.sh'" || {
		log "ERROR: ${host} rpeer helper check failed"
		exit 1
	}
done

"${SCRIPT_DIR}/sync_to_hosts.sh" "${CONFIG_FILE}"
for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	remote "${host}" "bash '${REMOTE_SETUP_DIR}/scripts/build_oncache.sh' '${REMOTE_ONCACHE_DIR}'"
done

"${SCRIPT_DIR}/restore_overlay_netperf.sh" "${CONFIG_FILE}"
"${SCRIPT_DIR}/start_oncache.sh" "${CONFIG_FILE}"

log "Warmup netperf (30s)..."
remote "${CLIENT_HOST}" \
	"docker exec '${CLIENT_CONTAINER}' netperf -H '10.0.1.2' -t TCP_RR -l 30 -- -r 64,64" || true

BENCH_ROOT="$(cd "${SCRIPT_DIR}/../oncache-benchmark" && pwd)"
if [[ -f "${BENCH_ROOT}/run_mixed_netperf.sh" ]]; then
	log "Running unified mixed benchmark (overlay lab: skip ipvlan migrate)..."
	IPVLAN_PREPARE_EACH_RUN=0 RUN_MODE=oncache bash "${BENCH_ROOT}/run_mixed_netperf.sh" "${BENCH_ROOT}/benchmark.conf"
fi

log "Done — check ${BENCH_ROOT}/results/oncache/"
