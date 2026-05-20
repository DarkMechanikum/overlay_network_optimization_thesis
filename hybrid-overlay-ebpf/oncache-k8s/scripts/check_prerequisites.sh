#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

log "Checking cluster and ONCache prerequisites"

remote "${MASTER_HOST}" "kubectl get nodes"
kubectl_remote "get pods '${SERVER_POD}' '${CLIENT_POD}'"

for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	remote "${host}" "test -x '${REMOTE_ONCACHE_DIR}/user_prog/tc_prog_loader'"
	remote "${host}" "test -f '${REMOTE_ONCACHE_DIR}/tc_prog/tc_prog_kern.o'"
done

kubectl_remote "exec '${SERVER_POD}' -- netserver -V"
kubectl_remote "exec '${CLIENT_POD}' -- netperf -V"

log "Prerequisites OK"
