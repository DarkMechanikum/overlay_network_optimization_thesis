#!/usr/bin/env bash
# Revert the Falcon-style fallback applied by apply_falcon_fallback.sh by
# restoring each tuned sysfs queue mask and net.core sysctl from the per-host
# state file. Safe to invoke when no fallback is active.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYBRID_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HYBRID_OVERLAY_ROOT="$(cd "${HYBRID_ROOT}/.." && pwd)"

# shellcheck source=../../oncache-k8s/scripts/lib.sh
source "${HYBRID_OVERLAY_ROOT}/oncache-k8s/scripts/lib.sh"

CONFIG_FILE="${1:-${HYBRID_OVERLAY_ROOT}/oncache-k8s/conf/oncache_k8s_setup.conf}"
FALCON_CONF="${2:-${HYBRID_ROOT}/conf/falcon_fallback.conf}"

load_config "${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${FALCON_CONF}"

revert_on_host() {
	local host="$1"
	log "Reverting Falcon fallback on ${host}"
	remote_bash "${host}" <<EOF
set -euo pipefail

STATE_DIR='${FALCON_STATE_DIR}'
STATE_FILE="\${STATE_DIR}/falcon_state.tsv"

if [[ ! -s "\${STATE_FILE}" ]]; then
	echo "[falcon-fallback] no state file at \${STATE_FILE}, nothing to revert"
	exit 0
fi

while IFS=\$'\t' read -r kind name path value; do
	case "\${kind}" in
	rps|xps)
		[[ -w "\${path}" ]] || continue
		echo "\${value:-0}" > "\${path}" 2>/dev/null || true
		;;
	sysctl)
		[[ -n "\${value}" ]] || continue
		sysctl -w "\${name}=\${value}" >/dev/null 2>&1 || true
		;;
	esac
done < "\${STATE_FILE}"

rm -f "\${STATE_FILE}"
echo "[falcon-fallback] reverted on \$(hostname)"
EOF
}

revert_on_host "${SERVER_HOST}"
revert_on_host "${CLIENT_HOST}"

log "Falcon-style fallback removed"
