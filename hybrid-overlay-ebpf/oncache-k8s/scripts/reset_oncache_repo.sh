#!/usr/bin/env bash
# Reset ONCache git tree on lab hosts (clean upstream state for K8s build).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

reset_host() {
	local host="$1"
	log "Resetting ONCache repo on ${host}"
	remote_bash "${host}" <<EOF
set -euo pipefail
if [[ ! -d '${REMOTE_ONCACHE_DIR}/.git' ]]; then
	echo "No git repo at ${REMOTE_ONCACHE_DIR}; will be populated by sync"
	exit 0
fi
cd '${REMOTE_ONCACHE_DIR}'
git reset --hard HEAD
git clean -fdx
git submodule sync --recursive
git submodule update --init --recursive --force
EOF
}

for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	reset_host "${host}"
done

log "ONCache repo reset complete on both nodes"
