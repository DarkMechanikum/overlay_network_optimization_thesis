#!/usr/bin/env bash
set -euo pipefail

ONCACHE_DIR="${1:-/root/ONCache}"
NODE_IFNAME="${2:?Usage: $0 [oncache-dir] <node-ifname> [container-name] [container-ifname]}"
CONTAINER="${3:-}"
CONTAINER_IFNAME="${4:-eth0}"
LOADER="${ONCACHE_DIR}/user_prog/tc_prog_loader"

if [[ ! -x "${LOADER}" ]]; then
	echo "Missing loader: ${LOADER}" >&2
	exit 1
fi

rm -rf /sys/fs/bpf/tc/globals/* 2>/dev/null || true
"${LOADER}" --dev "${NODE_IFNAME}" --remove --egress || true
"${LOADER}" --dev "${NODE_IFNAME}" --remove || true

if [[ -n "${CONTAINER}" ]]; then
	# shellcheck source=lib.sh
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=find_container_attachment.sh
	eval "$("${SCRIPT_DIR}/find_container_attachment.sh" "${CONTAINER}" "${CONTAINER_IFNAME}")"
	if [[ -n "${NETNS:-}" ]]; then
		nsenter --net="${NETNS}" "${LOADER}" --dev "${IFACE:-}" --remove || true
	else
		"${LOADER}" --dev "${IFACE:-}" --remove || true
	fi
	if [[ -n "${CONTAINER_PID:-}" ]]; then
		nsenter --net="/proc/${CONTAINER_PID}/ns/net" "${LOADER}" --dev "${CONTAINER_IFNAME}" --remove || true
	fi
fi

echo "ONCache detached on $(hostname)"
