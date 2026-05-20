#!/usr/bin/env bash
set -euo pipefail

ONCACHE_DIR="${1:?Usage: $0 <oncache-source-dir>}"

if [[ ! -d "${ONCACHE_DIR}" ]]; then
	echo "ONCache source directory not found: ${ONCACHE_DIR}" >&2
	exit 1
fi

rm -rf "${ONCACHE_DIR}/yaml-cpp/build"
# SWARM_LAB: relax Antrea TOS/policy gating for cache learning on Swarm.
# SWARM_OVERLAY_SANDBOX: masq encap+redirect breaks overlay until maps are warm (keep slow-path masq).
# SWARM_OVERLAY_RESTORE: tc_restore on overlay vxlan0 (same-netns bpf_redirect).
# Set ONCACHE_OVERLAY_FLAGS='' for full fast path on ipvlan/K8s-style host veth.
PROBE_RPEER=0
if command -v bpftool >/dev/null 2>&1 && bpftool feature probe kernel 2>/dev/null | grep -q 'redirect_rpeer'; then
	PROBE_RPEER=1
elif grep -q 'bpf_redirect_rpeer' /proc/kallsyms 2>/dev/null; then
	PROBE_RPEER=1
fi
if [[ -z "${ONCACHE_OVERLAY_FLAGS+x}" ]]; then
	if [[ "${PROBE_RPEER}" -eq 1 ]]; then
		OVERLAY_FLAGS="-DSWARM_OVERLAY_RESTORE -DSWARM_USE_RPEER"
	else
		OVERLAY_FLAGS="-DSWARM_OVERLAY_SANDBOX -DSWARM_OVERLAY_RESTORE"
	fi
else
	OVERLAY_FLAGS="${ONCACHE_OVERLAY_FLAGS}"
fi
IPVLAN_FLAGS=""
if [[ "${ONCACHE_IPVLAN_L3:-0}" == "1" ]]; then
	IPVLAN_FLAGS="-DONCACHE_IPVLAN_L3"
elif [[ -n "${ONCACHE_OVERLAY_FLAGS+x}" && -z "${ONCACHE_OVERLAY_FLAGS}" ]]; then
	IPVLAN_FLAGS="-DONCACHE_IPVLAN_L3"
fi
make -C "${ONCACHE_DIR}" all EXTRA_CFLAGS="-DSWARM_LAB ${OVERLAY_FLAGS} ${IPVLAN_FLAGS}"
echo "Built ONCache in ${ONCACHE_DIR} (SWARM_LAB ${OVERLAY_FLAGS} ${IPVLAN_FLAGS})"
