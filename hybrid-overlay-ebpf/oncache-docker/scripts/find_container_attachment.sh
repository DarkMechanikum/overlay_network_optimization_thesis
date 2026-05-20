#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${1:?Usage: $0 <container-name>}"
CONTAINER_IFNAME="${2:-eth0}"

if ! command -v docker >/dev/null 2>&1; then
	echo "docker is required" >&2
	exit 1
fi

PID="$(docker inspect -f '{{.State.Pid}}' "${CONTAINER}")"
if [[ -z "${PID}" || "${PID}" == "0" ]]; then
	echo "Container ${CONTAINER} is not running" >&2
	exit 1
fi

CONTAINER_IP="$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "${CONTAINER}")"
if [[ -z "${CONTAINER_IP}" ]]; then
	echo "Could not determine container IP for ${CONTAINER}" >&2
	exit 1
fi

LINK_LINE="$(nsenter -t "${PID}" -n ip -o link show "${CONTAINER_IFNAME}" 2>/dev/null || true)"
if [[ -z "${LINK_LINE}" ]]; then
	echo "Could not find ${CONTAINER_IFNAME} inside ${CONTAINER}" >&2
	exit 1
fi

PEER_IFINDEX="$(sed -n "s/.*${CONTAINER_IFNAME}@if\\([0-9]\\+\\).*/\\1/p" <<<"${LINK_LINE}")"
if [[ -z "${PEER_IFINDEX}" ]]; then
	echo "Could not parse peer ifindex from: ${LINK_LINE}" >&2
	exit 1
fi

HOST_LINE="$(ip -o link | awk -v idx="${PEER_IFINDEX}" '$1 == idx":" {print; exit}')"
NETNS=""
HOST_IFACE=""
if [[ -n "${HOST_LINE}" ]]; then
	HOST_IFACE="$(awk -F': ' '{print $2}' <<<"${HOST_LINE}" | cut -d@ -f1)"
else
	for NETNS_PATH in /var/run/docker/netns/*; do
		[[ -e "${NETNS_PATH}" ]] || continue
		HOST_LINE="$(nsenter --net="${NETNS_PATH}" ip -o link | awk -v idx="${PEER_IFINDEX}" '$1 == idx":" {print; exit}')"
		if [[ -z "${HOST_LINE}" ]]; then
			continue
		fi
		NETNS="${NETNS_PATH}"
		HOST_IFACE="$(awk -F': ' '{print $2}' <<<"${HOST_LINE}" | cut -d@ -f1)"
		break
	done
fi

if [[ -z "${HOST_IFACE}" ]]; then
	echo "Could not find host-side interface for peer ifindex ${PEER_IFINDEX}" >&2
	exit 1
fi

VXLAN_IFACE=""
VXLAN_IFINDEX=""
if [[ -n "${NETNS}" ]]; then
	VXLAN_LINE="$(nsenter --net="${NETNS}" ip -o link show 2>/dev/null | { grep -m1 vxlan || true; })"
	if [[ -n "${VXLAN_LINE}" ]]; then
		VXLAN_IFINDEX="$(awk -F: '{print $1}' <<<"${VXLAN_LINE}" | tr -d ' ')"
		VXLAN_IFACE="$(awk -F': ' '{print $2}' <<<"${VXLAN_LINE}" | cut -d@ -f1)"
	fi
fi

printf 'CONTAINER_IP=%s\n' "${CONTAINER_IP}"
printf 'CONTAINER_PID=%s\n' "${PID}"
printf 'PEER_IFINDEX=%s\n' "${PEER_IFINDEX}"
printf 'NETNS=%s\n' "${NETNS}"
printf 'IFACE=%s\n' "${HOST_IFACE}"
printf 'VXLAN_IFACE=%s\n' "${VXLAN_IFACE}"
printf 'VXLAN_IFINDEX=%s\n' "${VXLAN_IFINDEX}"
if [[ -n "${NETNS}" && -n "${HOST_IFACE}" ]]; then
	LOCAL_VETH_IFINDEX="$(nsenter --net="${NETNS}" cat "/sys/class/net/${HOST_IFACE}/ifindex" 2>/dev/null || true)"
	printf 'LOCAL_VETH_IFINDEX=%s\n' "${LOCAL_VETH_IFINDEX}"
fi
