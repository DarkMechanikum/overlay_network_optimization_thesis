#!/usr/bin/env bash
# Apply a Falcon-style multi-core fallback: spread RX/TX softirq processing
# across all CPUs via RPS/XPS on the transport NIC, physical NIC, and any
# Geneve/Antrea/OVS/veth devices we can discover on each node.
#
# Designed to compose with ONCache: the cache fast path remains the primary
# accelerator; this script ensures that anything ONCache does *not* short-cut
# (cold flows, cache misses, the periodic fallback chain) is no longer
# serialised on a single core.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYBRID_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HYBRID_OVERLAY_ROOT="$(cd "${HYBRID_ROOT}/.." && pwd)"

# Reuse the existing K8s harness helpers (remote_bash, load_config).
# shellcheck source=../../oncache-k8s/scripts/lib.sh
source "${HYBRID_OVERLAY_ROOT}/oncache-k8s/scripts/lib.sh"

CONFIG_FILE="${1:-${HYBRID_OVERLAY_ROOT}/oncache-k8s/conf/oncache_k8s_setup.conf}"
FALCON_CONF="${2:-${HYBRID_ROOT}/conf/falcon_fallback.conf}"

load_config "${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${FALCON_CONF}"

apply_on_host() {
	local host="$1"
	local transport="$2"
	local physical="$3"

	log "Applying Falcon fallback on ${host} (transport=${transport}, physical=${physical})"

	remote_bash "${host}" <<EOF
set -euo pipefail

TRANSPORT='${transport}'
PHYSICAL='${physical}'
STATE_DIR='${FALCON_STATE_DIR}'
EXTRA_PATTERNS='${FALCON_EXTRA_IFACE_PATTERNS}'
RPS_MASK_OVERRIDE='${FALCON_RPS_CPU_MASK}'
XPS_MASK_OVERRIDE='${FALCON_XPS_CPU_MASK}'
NETDEV_BUDGET='${FALCON_NETDEV_BUDGET}'
NETDEV_MAX_BACKLOG='${FALCON_NETDEV_MAX_BACKLOG}'

mkdir -p "\${STATE_DIR}"
STATE_FILE="\${STATE_DIR}/falcon_state.tsv"

compute_mask() {
	if [[ -n "\${RPS_MASK_OVERRIDE}" ]]; then
		printf '%s' "\${RPS_MASK_OVERRIDE}"
		return
	fi
	local n
	n=\$(nproc)
	# Build a hex mask with N low bits set. Works for any reasonable core count
	# without depending on bc/python.
	python3 -c "print('%x' % ((1 << \${n}) - 1))"
}

resolved_mask=\$(compute_mask)
xps_mask="\${XPS_MASK_OVERRIDE:-\${resolved_mask}}"

# Build the candidate interface list: explicit NICs plus anything matching the
# extra patterns currently present in /sys/class/net.
ifaces=()
for explicit in "\${TRANSPORT}" "\${PHYSICAL}"; do
	[[ -n "\${explicit}" ]] || continue
	[[ -e "/sys/class/net/\${explicit}" ]] || continue
	ifaces+=("\${explicit}")
done
for pattern in \${EXTRA_PATTERNS}; do
	while IFS= read -r ifname; do
		ifaces+=("\${ifname}")
	done < <(ls /sys/class/net 2>/dev/null | grep -E "\${pattern}" || true)
done

# De-duplicate while preserving order.
declare -A seen=()
unique_ifaces=()
for nic in "\${ifaces[@]}"; do
	if [[ -z "\${seen[\${nic}]:-}" ]]; then
		seen["\${nic}"]=1
		unique_ifaces+=("\${nic}")
	fi
done

if [[ \${#unique_ifaces[@]} -eq 0 ]]; then
	echo "[falcon-fallback] no interfaces to tune on \$(hostname)" >&2
	exit 0
fi

# Persist current state once per apply (overwrites any previous unreverted run).
: > "\${STATE_FILE}"

write_if_writable() {
	local path="\$1"
	local value="\$2"
	[[ -w "\${path}" ]] || return 0
	echo "\${value}" > "\${path}" 2>/dev/null || true
}

for nic in "\${unique_ifaces[@]}"; do
	for q in /sys/class/net/\${nic}/queues/rx-*; do
		[[ -d "\${q}" ]] || continue
		f="\${q}/rps_cpus"
		[[ -f "\${f}" ]] || continue
		cur=\$(cat "\${f}" 2>/dev/null || echo "")
		printf 'rps\t%s\t%s\t%s\n' "\${nic}" "\${f}" "\${cur}" >> "\${STATE_FILE}"
		write_if_writable "\${f}" "\${resolved_mask}"
	done

	if [[ "\${xps_mask}" != "skip" ]]; then
		for q in /sys/class/net/\${nic}/queues/tx-*; do
			[[ -d "\${q}" ]] || continue
			f="\${q}/xps_cpus"
			[[ -f "\${f}" ]] || continue
			cur=\$(cat "\${f}" 2>/dev/null || echo "")
			printf 'xps\t%s\t%s\t%s\n' "\${nic}" "\${f}" "\${cur}" >> "\${STATE_FILE}"
			write_if_writable "\${f}" "\${xps_mask}"
		done
	fi
done

if [[ -n "\${NETDEV_BUDGET}" ]]; then
	cur=\$(sysctl -n net.core.netdev_budget 2>/dev/null || echo "")
	printf 'sysctl\tnet.core.netdev_budget\t\t%s\n' "\${cur}" >> "\${STATE_FILE}"
	sysctl -w net.core.netdev_budget="\${NETDEV_BUDGET}" >/dev/null 2>&1 || true
fi
if [[ -n "\${NETDEV_MAX_BACKLOG}" ]]; then
	cur=\$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "")
	printf 'sysctl\tnet.core.netdev_max_backlog\t\t%s\n' "\${cur}" >> "\${STATE_FILE}"
	sysctl -w net.core.netdev_max_backlog="\${NETDEV_MAX_BACKLOG}" >/dev/null 2>&1 || true
fi

echo "[falcon-fallback] mask=\${resolved_mask} ifaces=\${unique_ifaces[*]} state=\${STATE_FILE}"
EOF
}

apply_on_host "${SERVER_HOST}" "${SERVER_NODE_IFNAME}" "${SERVER_PHY_IFNAME:-}"
apply_on_host "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}" "${CLIENT_PHY_IFNAME:-}"

log "Falcon-style fallback active on ${SERVER_HOST} and ${CLIENT_HOST}"
