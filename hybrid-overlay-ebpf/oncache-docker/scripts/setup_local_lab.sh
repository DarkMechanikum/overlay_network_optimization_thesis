#!/usr/bin/env bash
# Bootstrap server3/server4 for ipvlan ONCache benchmark (LAN underlay).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_local_lab.conf}"
load_config "${CONFIG_FILE}"

SERVER_UNDERLAY="${SERVER_UNDERLAY:-192.168.40.136}"
CLIENT_UNDERLAY="${CLIENT_UNDERLAY:-192.168.40.177}"
SERVER3_SUDO_PASS="${SERVER3_SUDO_PASS:-server1pass}"
SERVER4_SUDO_PASS="${SERVER4_SUDO_PASS:-server2pass}"

discover_parent() {
	local host="$1"
	local peer_ip="$2"
	remote "${host}" "ip -4 route get '${peer_ip}' 2>/dev/null | awk '{for(i=1;i<=NF;i++) if (\$i==\"dev\") {print \$(i+1); exit}}'"
}

log "Discovering parent NICs (route to peer)"
srv_nic="$(discover_parent "${SERVER_HOST}" "${CLIENT_UNDERLAY}")"
cli_nic="$(discover_parent "${CLIENT_HOST}" "${SERVER_UNDERLAY}")"
log "${SERVER_HOST} parent -> ${srv_nic}; ${CLIENT_HOST} parent -> ${cli_nic}"

# Patch config on disk for this run (optional convenience).
if [[ -f "${SETUP_ROOT}/conf/oncache_local_lab.conf" ]]; then
	sed -i "s/^SERVER_NODE_IFNAME=.*/SERVER_NODE_IFNAME=\"${srv_nic}\"/" "${SETUP_ROOT}/conf/oncache_local_lab.conf"
	sed -i "s/^CLIENT_NODE_IFNAME=.*/CLIENT_NODE_IFNAME=\"${cli_nic}\"/" "${SETUP_ROOT}/conf/oncache_local_lab.conf"
	export SERVER_NODE_IFNAME="${srv_nic}" CLIENT_NODE_IFNAME="${cli_nic}"
fi

log "Installing dependencies (sudo)"
remote "${SERVER_HOST}" "SUDO_PASS=${SERVER3_SUDO_PASS} bash -s" < "${SCRIPT_DIR}/install_deps_sudo.sh"
remote "${CLIENT_HOST}" "SUDO_PASS=${SERVER4_SUDO_PASS} bash -s" < "${SCRIPT_DIR}/install_deps_sudo.sh"

log "Ensure docker works for ${USER:-vlad}"
for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	remote "${host}" "sg docker -c 'docker info >/dev/null' 2>/dev/null || docker info >/dev/null"
done

"${SCRIPT_DIR}/init_submodules.sh"
"${SCRIPT_DIR}/sync_to_hosts.sh" "${CONFIG_FILE}"

for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	log "Building ONCache on ${host}"
	remote "${host}" "bash '${REMOTE_SETUP_DIR}/scripts/build_oncache.sh' '${REMOTE_ONCACHE_DIR}'"
done

export SERVER_UNDERLAY CLIENT_UNDERLAY
"${SCRIPT_DIR}/check_vswitch.sh" "${CONFIG_FILE}"
"${SCRIPT_DIR}/migrate_netperf_to_ipvlan.sh" "${CONFIG_FILE}"

log "Local lab ready. Run benchmark:"
log "  cd oncache-benchmark && RUN_MODE=baseline ./run_mixed_netperf.sh ./benchmark.local.conf"
