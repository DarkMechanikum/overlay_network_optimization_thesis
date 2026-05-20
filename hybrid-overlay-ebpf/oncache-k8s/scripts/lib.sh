#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
THESIS_ROOT="$(cd "${SETUP_ROOT}/../.." && pwd)"
ONCACHE_SRC="${THESIS_ROOT}/references/ONCache"

log() {
	printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

load_config() {
	local config_file="${1:?config file required}"
	# shellcheck source=/dev/null
	source "${config_file}"
	: "${MASTER_HOST:?Missing MASTER_HOST}"
	: "${SERVER_HOST:?Missing SERVER_HOST}"
	: "${CLIENT_HOST:?Missing CLIENT_HOST}"
	: "${SERVER_NODE_NAME:?Missing SERVER_NODE_NAME}"
	: "${CLIENT_NODE_NAME:?Missing CLIENT_NODE_NAME}"
	: "${SERVER_POD:?Missing SERVER_POD}"
	: "${CLIENT_POD:?Missing CLIENT_POD}"
	: "${NAMESPACE:?Missing NAMESPACE}"
	: "${SERVER_NODE_IFNAME:?Missing SERVER_NODE_IFNAME}"
	: "${CLIENT_NODE_IFNAME:?Missing CLIENT_NODE_IFNAME}"
	: "${REMOTE_ONCACHE_DIR:?Missing REMOTE_ONCACHE_DIR}"
	: "${REMOTE_SETUP_DIR:?Missing REMOTE_SETUP_DIR}"
	SSH_OPTS=${SSH_OPTS:-""}
	POD_NETWORK_CIDR=${POD_NETWORK_CIDR:-10.10.0.0/16}
	ANTREA_VERSION=${ANTREA_VERSION:-v1.10.0}
	NAMESPACE=${NAMESPACE:-default}
}

remote() {
	local host="$1"
	shift
	# shellcheck disable=SC2086
	ssh -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
		${SSH_OPTS} "${host}" "$@"
}

remote_bash() {
	local host="$1"
	shift
	# shellcheck disable=SC2086
	ssh ${SSH_OPTS} "${host}" "bash -s" -- "$@"
}

kubectl_remote() {
	remote "${MASTER_HOST}" "kubectl -n '${NAMESPACE}' $*"
}

# Run kubectl on master with a wall-clock limit (avoids hung netperf/exec).
kubectl_remote_timeout() {
	local secs="$1"
	shift
	remote "${MASTER_HOST}" "timeout --foreground ${secs} kubectl -n '${NAMESPACE}' $*"
}
