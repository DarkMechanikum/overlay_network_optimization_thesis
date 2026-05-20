#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

PIDFILE="/run/oncache-cpu-stress.pid"

stop_on_host() {
	local host="$1"
	log "Stopping CPU stress on ${host}"
	remote_bash "${host}" <<EOF
set -euo pipefail
run_sudo() { if [[ "\$(id -u)" -eq 0 ]]; then "\$@"; else sudo -n "\$@"; fi; }
if [[ -f '${PIDFILE}' ]]; then
  pid=\$(cat '${PIDFILE}' 2>/dev/null || true)
  run_sudo kill "\${pid}" 2>/dev/null || true
fi
run_sudo pkill -x stress-ng 2>/dev/null || true
run_sudo rm -f '${PIDFILE}'
echo "stress-ng stopped on \$(hostname); loadavg: \$(cut -d' ' -f1-3 /proc/loadavg)"
EOF
}

stop_on_host "${SERVER_HOST}"
stop_on_host "${CLIENT_HOST}"
log "CPU stress teardown complete"
