#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${1:?Usage: $0 <container-name>}"

if ! command -v docker >/dev/null 2>&1; then
	echo "docker is required" >&2
	exit 1
fi

PID="$(docker inspect -f '{{.State.Pid}}' "${CONTAINER}")"
if [[ -z "${PID}" || "${PID}" == "0" ]]; then
	echo "Container ${CONTAINER} is not running" >&2
	exit 1
fi

LINK_LINE="$(nsenter -t "${PID}" -n ip -o link show eth0 2>/dev/null || true)"
if [[ -z "${LINK_LINE}" ]]; then
	echo "Could not find eth0 inside ${CONTAINER}" >&2
	exit 1
fi

CONTAINER_IFINDEX="$(awk -F': ' '{print $1}' <<<"${LINK_LINE}" | tr -d ' ')"
PEER_IFINDEX="$(sed -n 's/.*eth0@if\([0-9]\+\).*/\1/p' <<<"${LINK_LINE}")"
if [[ -z "${PEER_IFINDEX}" ]]; then
	echo "Could not parse peer ifindex from: ${LINK_LINE}" >&2
	exit 1
fi

HOST_LINE="$(ip -o link | awk -v idx="${PEER_IFINDEX}" '$1 == idx":" {print; exit}')"
if [[ -n "${HOST_LINE}" ]]; then
	HOST_IFACE="$(awk -F': ' '{print $2}' <<<"${HOST_LINE}" | cut -d@ -f1)"
	printf 'NETNS=\nIFACE=%s\n' "${HOST_IFACE}"
	exit 0
fi

for NETNS_PATH in /var/run/docker/netns/*; do
	[[ -e "${NETNS_PATH}" ]] || continue
	HOST_LINE="$(nsenter --net="${NETNS_PATH}" ip -o link | awk -v idx="${PEER_IFINDEX}" '$1 == idx":" {print; exit}')"
	if [[ -z "${HOST_LINE}" ]]; then
		continue
	fi
	HOST_IFACE="$(awk -F': ' '{print $2}' <<<"${HOST_LINE}" | cut -d@ -f1)"
	printf 'NETNS=%s\nIFACE=%s\n' "${NETNS_PATH}" "${HOST_IFACE}"
	exit 0
done

echo "Could not find host-side veth for container ifindex ${CONTAINER_IFINDEX} peer ${PEER_IFINDEX}" >&2
exit 1
