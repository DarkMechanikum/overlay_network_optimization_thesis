#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-./tests/phase1_real_setup.conf}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULT_DIR="${RESULT_ROOT:-./tests/results}/manual_test9_$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${RESULT_DIR}"

SSH_OPTS=${SSH_OPTS:-""}
remote_client() {
	# shellcheck disable=SC2086
	ssh ${SSH_OPTS} "${CLIENT_HOST}" "$@"
}

rsync -az --exclude 'build/' --exclude 'tests/results/' "${PHASE1_ROOT}/" "${CLIENT_HOST}:${REMOTE_PHASE1_DIR}/"
remote_client "cd '${REMOTE_PHASE1_DIR}' && CLANG=clang-10 ./scripts/build.sh"

eval "$(remote_client "eval \$(${REMOTE_PHASE1_DIR}/scripts/find_container_veth.sh '${CLIENT_CONTAINER}') && printf 'CLIENT_NETNS=%q CLIENT_VETH=%q' \"\$NETNS\" \"\$IFACE\"")"
remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/detach.sh' '${CLIENT_VETH}'" >/dev/null 2>&1 || true
remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/attach.sh' '${CLIENT_VETH}'"
remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/dump_counters.sh' '${CLIENT_VETH}'" > "${RESULT_DIR}/before.txt"
remote_client "docker exec '${CLIENT_CONTAINER}' netperf -H '${SERVER_CONTAINER_IP}' -t TCP_RR -l 20 -- -r 64,64 >'${REMOTE_PHASE1_DIR}/test9.log' 2>&1 &"
sleep 2
remote_client "NETNS='${CLIENT_NETNS}' python3 '${REMOTE_PHASE1_DIR}/user/dump_flows.py' --iface '${CLIENT_VETH}' --limit 1" > "${RESULT_DIR}/flows.txt"
read -r _top src_ip src_port dst_ip dst_port proto < <(awk 'NR > 1 {print $6, $1, $2, $3, $4, $5}' "${RESULT_DIR}/flows.txt" | sort -nr | head -1)
remote_client "NETNS='${CLIENT_NETNS}' python3 '${REMOTE_PHASE1_DIR}/user/insert_hot_flow.py' --iface '${CLIENT_VETH}' --src-ip '${src_ip}' --dst-ip '${dst_ip}' --src-port '${src_port}' --dst-port '${dst_port}' --proto tcp"
sleep 5
remote_client "wait" >/dev/null 2>&1 || true
remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/dump_counters.sh' '${CLIENT_VETH}'" > "${RESULT_DIR}/after.txt"
remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/detach.sh' '${CLIENT_VETH}'" >/dev/null 2>&1 || true

echo "Selected flow: ${src_ip}:${src_port} -> ${dst_ip}:${dst_port} (${proto})"
echo "Before:"
grep -E 'CNT_HOT_PACKETS|CNT_FALLBACK_PACKETS' "${RESULT_DIR}/before.txt"
echo "After:"
grep -E 'CNT_HOT_PACKETS|CNT_FALLBACK_PACKETS' "${RESULT_DIR}/after.txt"
