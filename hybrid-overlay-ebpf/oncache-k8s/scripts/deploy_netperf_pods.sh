#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

MANIFEST_LOCAL="${SETUP_ROOT}/manifests/netperf-pods.yaml"
REMOTE_MANIFEST="${REMOTE_SETUP_DIR}/manifests/netperf-pods.yaml"

# Patch nodeName placeholders to configured names.
TMP="$(mktemp)"
sed \
	-e "s/nodeName: node1/nodeName: ${SERVER_NODE_NAME}/" \
	-e "s/nodeName: node2/nodeName: ${CLIENT_NODE_NAME}/" \
	"${MANIFEST_LOCAL}" >"${TMP}"

remote "${MASTER_HOST}" "mkdir -p '${REMOTE_SETUP_DIR}/manifests'"
scp ${SSH_OPTS} "${TMP}" "${MASTER_HOST}:${REMOTE_MANIFEST}"
rm -f "${TMP}"
remote "${MASTER_HOST}" "kubectl delete pod '${SERVER_POD}' '${CLIENT_POD}' -n '${NAMESPACE}' --ignore-not-found=true --wait=false --grace-period=10"
sleep 5
remote "${MASTER_HOST}" "kubectl delete pod '${SERVER_POD}' '${CLIENT_POD}' -n '${NAMESPACE}' --ignore-not-found=true --force --grace-period=0 2>/dev/null || true"
remote "${MASTER_HOST}" "kubectl apply -f '${REMOTE_MANIFEST}' -n '${NAMESPACE}'"
remote "${MASTER_HOST}" "kubectl wait --for=condition=Ready pod/'${SERVER_POD}' -n '${NAMESPACE}' --timeout=180s"
remote "${MASTER_HOST}" "kubectl wait --for=condition=Ready pod/'${CLIENT_POD}' -n '${NAMESPACE}' --timeout=180s"
remote "${MASTER_HOST}" "kubectl get pods -n '${NAMESPACE}' -o wide"

log "Netperf pods ready"
