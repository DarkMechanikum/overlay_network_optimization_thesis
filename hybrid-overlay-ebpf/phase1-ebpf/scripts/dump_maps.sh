#!/usr/bin/env bash
set -euo pipefail

MAP_NAME="${1:?Usage: $0 <map-name> [iface]}"
IFACE="${2:-}"

if ! command -v bpftool >/dev/null 2>&1; then
	echo "bpftool is required" >&2
	exit 1
fi

map_id=""
if [[ -n "${IFACE}" ]]; then
	while read -r line; do
		if [[ "${line}" == *"name ${MAP_NAME}"* ]]; then
			map_id="$(awk '{print $1}' <<<"${line}" | tr -d ':')"
			break
		fi
	done < <(sudo bpftool net show dev "${IFACE}" 2>/dev/null || true)
fi

if [[ -z "${map_id}" ]]; then
	map_id="$(sudo bpftool map show name "${MAP_NAME}" -j 2>/dev/null | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data[0]["id"] if data else "")' 2>/dev/null || true)"
fi

if [[ -z "${map_id}" ]]; then
	echo "Could not locate map ${MAP_NAME}" >&2
	exit 1
fi

sudo bpftool map dump id "${map_id}"
