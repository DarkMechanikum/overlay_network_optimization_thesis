#!/usr/bin/env bash
# Quick status: cluster, overlay stress, latest summary.csv tail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

echo "=== SSH ==="
for h in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	ssh -o ConnectTimeout=5 "${h}" 'echo OK:'"$(hostname)" 2>&1 || echo "FAIL: ${h}"
done

echo "=== Kubernetes ==="
remote "${MASTER_HOST}" "kubectl get nodes -o wide; kubectl get pods -n '${NAMESPACE}' -o wide; kubectl -n '${NAMESPACE}' get networkpolicy 2>/dev/null | wc -l | xargs echo 'NetworkPolicy count:'"

echo "=== CPU stress ==="
for h in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	ssh -o ConnectTimeout=5 "${h}" 'pgrep -a stress-ng | head -2 || echo no stress-ng; cat /proc/loadavg' 2>&1 || echo "FAIL: ${h}"
done

echo "=== Latest overlay-stress results ==="
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)/results/k8s-latency-overlay-stress"
if [[ -d "${ROOT}" ]]; then
	latest="$(find "${ROOT}" -name summary.csv -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
	if [[ -n "${latest}" ]]; then
		echo "File: ${latest}"
		tail -20 "${latest}"
	else
		echo "(no summary.csv yet)"
	fi
else
	echo "(no results dir)"
fi
