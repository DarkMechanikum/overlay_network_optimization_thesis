#!/usr/bin/env bash
# Full lab prep: deps, K8s+Antrea, ONCache reset/sync/build, netperf pods.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
SKIP_PROVISION="${SKIP_PROVISION:-0}"
load_config "${CONFIG_FILE}"

"${SCRIPT_DIR}/install_k8s_deps.sh" "${CONFIG_FILE}"
"${SCRIPT_DIR}/reset_oncache_repo.sh" "${CONFIG_FILE}" || true
"${SCRIPT_DIR}/sync_to_hosts.sh" "${CONFIG_FILE}"

for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	log "Building ONCache on ${host}"
	remote "${host}" "bash '${REMOTE_SETUP_DIR}/scripts/build_oncache.sh' '${REMOTE_ONCACHE_DIR}'"
done

if [[ "${SKIP_PROVISION}" != "1" ]]; then
	"${SCRIPT_DIR}/provision_cluster.sh" "${CONFIG_FILE}"
fi

"${SCRIPT_DIR}/deploy_netperf_pods.sh" "${CONFIG_FILE}"
"${SCRIPT_DIR}/check_prerequisites.sh" "${CONFIG_FILE}"
log "Lab preparation complete (Kubernetes+Antrea runtime: containerd)."
