#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

require_kernel() {
	local host="$1"
	remote_bash "${host}" <<'EOF'
set -euo pipefail
python3 - <<'PY'
import subprocess
release = subprocess.check_output(["uname", "-r"], text=True).strip()
major, minor = map(int, release.split(".")[:2])
if (major, minor) < (5, 13):
    raise SystemExit(
        "ONCache requires Linux >= 5.13; host runs "
        + release
        + ". Run ./scripts/probe_tc_load.sh after upgrading the kernel."
    )
PY
EOF
}

if [[ "${ONCACHE_SKIP_KERNEL_CHECK:-0}" == 1 ]]; then
	log "Skipping kernel version check (ONCACHE_SKIP_KERNEL_CHECK=1)"
else
	require_kernel "${SERVER_HOST}"
	require_kernel "${CLIENT_HOST}"
fi

start_host() {
	local host="$1"
	local node_ifname="$2"
	local container="$3"
	local remote_pod="$4"
	local remote_underlay="$5"
	local sudo_pass=""
	if [[ "${host}" == "${SERVER_HOST}" ]]; then
		sudo_pass="${SERVER3_SUDO_PASS:-${SUDO_PASS:-}}"
	else
		sudo_pass="${SERVER4_SUDO_PASS:-${SUDO_PASS:-}}"
	fi
	log "Starting ONCache daemon on ${host} for ${container}"
	remote_bash "${host}" <<EOF
set -euo pipefail
export ONCACHE_SUDO_PASS='${sudo_pass}'
export ONCACHE_REMOTE_POD_IP='${remote_pod}'
export ONCACHE_REMOTE_UNDERLAY='${remote_underlay}'
pkill -f "docker_daemon.py --node-ifname ${node_ifname}" 2>/dev/null || true
nohup env ONCACHE_SUDO_PASS="\${ONCACHE_SUDO_PASS}" ONCACHE_REMOTE_POD_IP="\${ONCACHE_REMOTE_POD_IP}" ONCACHE_REMOTE_UNDERLAY="\${ONCACHE_REMOTE_UNDERLAY}" python3 "${REMOTE_SETUP_DIR}/user/docker_daemon.py" \
	--oncache-dir "${REMOTE_ONCACHE_DIR}" \
	--setup-dir "${REMOTE_SETUP_DIR}" \
	--node-ifname "${node_ifname}" \
	--containers "${container}" \
	>"${REMOTE_SETUP_DIR}/daemon.log" 2>&1 &
sleep 2
pgrep -af docker_daemon.py || { echo "ONCache daemon failed to start"; exit 1; }
EOF
}

IPVLAN_SERVER_IP="${IPVLAN_SERVER_IP:-10.0.3.2}"
IPVLAN_CLIENT_IP="${IPVLAN_CLIENT_IP:-10.0.3.3}"
SERVER_UNDERLAY="${SERVER_UNDERLAY:-168.119.133.106}"
CLIENT_UNDERLAY="${CLIENT_UNDERLAY:-168.119.133.107}"

start_host "${SERVER_HOST}" "${SERVER_NODE_IFNAME}" "${SERVER_CONTAINER}" "${IPVLAN_CLIENT_IP}" "${CLIENT_UNDERLAY}"
start_host "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}" "${CLIENT_CONTAINER}" "${IPVLAN_SERVER_IP}" "${SERVER_UNDERLAY}"
