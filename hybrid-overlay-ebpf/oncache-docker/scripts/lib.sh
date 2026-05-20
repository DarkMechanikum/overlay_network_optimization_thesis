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
	: "${SERVER_HOST:?Missing SERVER_HOST}"
	: "${CLIENT_HOST:?Missing CLIENT_HOST}"
	: "${SERVER_CONTAINER:?Missing SERVER_CONTAINER}"
	: "${CLIENT_CONTAINER:?Missing CLIENT_CONTAINER}"
	: "${OVERLAY_NETWORK:?Missing OVERLAY_NETWORK}"
	: "${CONTAINER_IFNAME:?Missing CONTAINER_IFNAME}"
	: "${SERVER_NODE_IFNAME:?Missing SERVER_NODE_IFNAME}"
	: "${CLIENT_NODE_IFNAME:?Missing CLIENT_NODE_IFNAME}"
	: "${REMOTE_ONCACHE_DIR:?Missing REMOTE_ONCACHE_DIR}"
	: "${REMOTE_SETUP_DIR:?Missing REMOTE_SETUP_DIR}"
	SSH_OPTS=${SSH_OPTS:-""}
	ENABLE_OVS_HOOKS=${ENABLE_OVS_HOOKS:-0}
}

remote() {
	local host="$1"
	shift
	# shellcheck disable=SC2086
	ssh ${SSH_OPTS} "${host}" "$@"
}

remote_bash() {
	local host="$1"
	shift
	# shellcheck disable=SC2086
	ssh ${SSH_OPTS} "${host}" "bash -s" -- "$@"
}
