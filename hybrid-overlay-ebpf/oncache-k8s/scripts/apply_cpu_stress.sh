#!/usr/bin/env bash
# Synthetic host CPU load via stress-ng (both nodes) to inflate overlay datapath cost.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

CPU_STRESS_LOAD="${CPU_STRESS_LOAD:-70}"
CPU_STRESS_RESERVE_CPUS="${CPU_STRESS_RESERVE_CPUS:-2}"
CPU_STRESS_WORKERS="${CPU_STRESS_WORKERS:-0}"
CPU_STRESS_METHOD="${CPU_STRESS_METHOD:-cpu}"
PIDFILE="/run/oncache-cpu-stress.pid"
LOGFILE="/var/log/oncache-cpu-stress.log"

apply_on_host() {
	local host="$1"
	log "CPU stress on ${host}: method=${CPU_STRESS_METHOD} load=${CPU_STRESS_LOAD}% workers=${CPU_STRESS_WORKERS:-auto}"
	remote_bash "${host}" <<EOF
set -euo pipefail
LOAD=${CPU_STRESS_LOAD}
RESERVE=${CPU_STRESS_RESERVE_CPUS}
WORKERS=${CPU_STRESS_WORKERS}
METHOD='${CPU_STRESS_METHOD}'
PIDFILE='${PIDFILE}'
LOGFILE='${LOGFILE}'

run_sudo() { if [[ "\$(id -u)" -eq 0 ]]; then "\$@"; else sudo -n "\$@"; fi; }

if ! command -v stress-ng >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq stress-ng
fi

run_sudo pkill -x stress-ng 2>/dev/null || true
sleep 1
run_sudo rm -f "\${PIDFILE}" "\${LOGFILE}"

NPROC=\$(nproc)
if [[ "\${WORKERS}" -le 0 ]]; then
  WORKERS=\$(( NPROC > RESERVE ? NPROC - RESERVE : 1 ))
fi
(( WORKERS < 1 )) && WORKERS=1

STARTER=\$(mktemp)
cat >"\${STARTER}" <<SCRIPT
#!/bin/bash
exec >>"\${LOGFILE}" 2>&1
echo "stress-ng start on \$(hostname) nproc=\${NPROC} workers=\${WORKERS} load=\${LOAD}% method=\${METHOD}"
if [[ "\${METHOD}" == "matrix" ]]; then
  exec stress-ng --matrix "\${WORKERS}" --matrix-method all --matrix-size 64 --timeout 0
else
  exec stress-ng --cpu "\${WORKERS}" --cpu-load "\${LOAD}" --timeout 0
fi
SCRIPT
chmod +x "\${STARTER}"
run_sudo mv "\${STARTER}" /usr/local/bin/oncache-cpu-stress.sh
run_sudo bash -c '/usr/local/bin/oncache-cpu-stress.sh & echo \$! > "'"\${PIDFILE}"'"'
sleep 2
pgrep -x stress-ng >/dev/null || { echo "stress-ng failed to start"; tail -20 "\${LOGFILE}" 2>/dev/null; exit 1; }
pgrep -a stress-ng | head -3 || true
echo "loadavg: \$(cut -d' ' -f1-3 /proc/loadavg)"
EOF
}

apply_on_host "${SERVER_HOST}"
apply_on_host "${CLIENT_HOST}"
log "CPU stress active on ${SERVER_HOST} and ${CLIENT_HOST}"
