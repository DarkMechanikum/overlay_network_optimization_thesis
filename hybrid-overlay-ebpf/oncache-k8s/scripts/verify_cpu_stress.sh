#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

MIN_LOAD_FACTOR="${CPU_STRESS_MIN_LOAD_FACTOR:-0.5}" # load1 >= nproc * factor

check_host() {
	local host="$1"
	remote_bash "${host}" <<EOF
set -euo pipefail
nproc=\$(nproc)
load1=\$(cut -d' ' -f1 /proc/loadavg)
echo "\$(hostname): nproc=\${nproc} load1=\${load1}"
pgrep -x stress-ng >/dev/null || { echo "stress-ng not running" >&2; exit 1; }
awk -v l="\${load1}" -v n="\${nproc}" -v f="${MIN_LOAD_FACTOR}" 'BEGIN { exit !(l >= n*f) }' || {
  echo "load \${load1} below threshold (nproc*${MIN_LOAD_FACTOR})" >&2
  exit 1
}
EOF
}

log "Verifying CPU stress on both nodes"
check_host "${SERVER_HOST}"
check_host "${CLIENT_HOST}"

SERVER_IP="$(kubectl_remote "get pod '${SERVER_POD}' -o jsonpath='{.status.podIP}'" 2>/dev/null || true)"
if [[ -z "${SERVER_IP}" ]]; then
	"${SCRIPT_DIR}/deploy_netperf_pods.sh" "${CONFIG_FILE}"
	SERVER_IP="$(kubectl_remote "get pod '${SERVER_POD}' -o jsonpath='{.status.podIP}'")"
fi


log "Starting netserver for smoke test"
kubectl_remote_timeout 30 \
	"exec '''${SERVER_POD}''' -- sh -c '''pkill netserver 2>/dev/null || true; netserver -D </dev/null >/dev/null 2>&1 & sleep 1; pgrep -x netserver >/dev/null || true'''" \
	|| true
for i in $(seq 1 15); do
	if kubectl_remote_timeout 20 \
		"exec '''${CLIENT_POD}''' -- netperf -H '''${SERVER_IP}''' -p 12865 -t TCP_RR -l 1 -- -r 64,64 -o MEAN_LATENCY" \
		>/dev/null 2>&1; then
		break
	fi
	[[ "${i}" -eq 15 ]] && { echo "netserver not ready on ${SERVER_IP}:12865" >&2; exit 1; }
	sleep 2
done

log "Pod smoke test under CPU stress (5s)"
kubectl_remote_timeout 30 \
	"exec '${CLIENT_POD}' -- netperf -H '${SERVER_IP}' -t TCP_RR -l 5 -- -r 64,64 -o MEAN_LATENCY,TRANSACTION_RATE"
log "verify_cpu_stress: OK"
