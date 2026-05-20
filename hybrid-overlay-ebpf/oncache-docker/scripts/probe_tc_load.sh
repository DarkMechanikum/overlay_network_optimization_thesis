#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

probe_host() {
	local host="$1"
	local node_ifname="$2"
	log "Probing ONCache TC load on ${host} (${node_ifname})"
	remote_bash "${host}" <<EOF
set -euo pipefail
loader="${REMOTE_ONCACHE_DIR}/user_prog/tc_prog_loader"
obj="${REMOTE_ONCACHE_DIR}/tc_prog/tc_prog_kern.o"
kernel="\$(uname -r)"
echo "kernel=\${kernel}"
python3 - <<'PY'
import subprocess
release = subprocess.check_output(["uname", "-r"], text=True).strip()
major, minor = map(int, release.split(".")[:2])
if (major, minor) < (5, 13):
    raise SystemExit(
        "ONCache requires Linux >= 5.13 on the host; current kernel is "
        + release
        + ". Upgrade the lab kernel or apply references/ONCache/rpeer_kernel_patch."
    )
PY
for section in tc_init_e tc_restore; do
	echo "== \${section} =="
	if [[ "\${section}" == "tc_init_e" ]]; then
		"\${loader}" --dev "${node_ifname}" --filename "\${obj}" --sec-name "\${section}" --egress --new-qdisc
	else
		"\${loader}" --dev "${node_ifname}" --filename "\${obj}" --sec-name "\${section}"
	fi
done
tc filter show dev "${node_ifname}" ingress
tc filter show dev "${node_ifname}" egress
EOF
}

probe_host "${SERVER_HOST}" "${SERVER_NODE_IFNAME}"
probe_host "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}"
