#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

stop_on_node() {
	local host="$1"
	local ifname="$2"
	log "Stopping ONCache on ${host}"
	remote_bash "${host}" <<EOF
set -euo pipefail
pkill -9 -f 'python3.*daemon.py' 2>/dev/null || true
sleep 1
LOADER='${REMOTE_ONCACHE_DIR}/user_prog/tc_prog_loader'
if [[ -x "\$LOADER" ]]; then
  "\$LOADER" --dev '${ifname}' --remove --egress 2>/dev/null || true
  "\$LOADER" --dev '${ifname}' --remove 2>/dev/null || true
  for veth in \$(ip -o link | awk -F': ' '{print \$2}' | cut -d@ -f1 | grep -- '--' || true); do
    "\$LOADER" --dev "\$veth" --remove 2>/dev/null || true
    "\$LOADER" --dev "\$veth" --remove --egress 2>/dev/null || true
  done
fi
rm -rf /sys/fs/bpf/tc/globals/* 2>/dev/null || true
EOF
}

stop_on_node "${SERVER_HOST}" "${SERVER_NODE_IFNAME}"
stop_on_node "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}"
log "ONCache stopped"
