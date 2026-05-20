#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

start_on_node() {
	local host="$1"
	local ifname="$2"
	log "Starting ONCache daemon on ${host} (NODE_IFNAME=${ifname})"
	remote_bash "${host}" <<EOF
set -euo pipefail
if [[ ! -x '${REMOTE_ONCACHE_DIR}/user_prog/tc_prog_loader' ]] || [[ ! -f '${REMOTE_ONCACHE_DIR}/tc_prog/tc_prog_kern.o' ]]; then
  bash '${REMOTE_SETUP_DIR}/scripts/build_oncache.sh' '${REMOTE_ONCACHE_DIR}'
fi
pkill -9 -f 'python3.*daemon.py' 2>/dev/null || true
sleep 1
bash '${REMOTE_SETUP_DIR}/scripts/patch_daemon.sh' '${REMOTE_ONCACHE_DIR}/user_prog' '${ifname}'
cd '${REMOTE_ONCACHE_DIR}/user_prog'
nohup python3 -u daemon.py >'${REMOTE_SETUP_DIR}/daemon.log' 2>&1 &
sleep 15
pgrep -af daemon.py || { echo 'daemon failed'; exit 1; }
EOF
}

start_on_node "${SERVER_HOST}" "${SERVER_NODE_IFNAME}"
start_on_node "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}"

log "Waiting for ONCache to discover pods"
sleep 20
kubectl_remote "get pods -o wide"
log "ONCache daemons started"
