#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

check_host() {
	local host="$1"
	local node_ifname="$2"
	local container="$3"
	log "Checking ${host}"
	remote_bash "${host}" <<EOF
set -euo pipefail
kernel="\$(uname -r)"
echo "kernel=\${kernel}"
if ! mountpoint -q /sys/fs/bpf; then
	echo "WARN: /sys/fs/bpf is not mounted"
fi
for tool in clang make cmake docker bpftool python3; do
	if ! command -v "\${tool}" >/dev/null 2>&1; then
		echo "MISSING: \${tool}"
	fi
done
for artifact in user_prog/tc_prog_loader user_prog/set_map tc_prog/tc_prog_kern.o; do
	if [[ ! -f "${REMOTE_ONCACHE_DIR}/\${artifact}" ]]; then
		echo "MISSING: ${REMOTE_ONCACHE_DIR}/\${artifact}"
	fi
done
if ! docker inspect "${container}" >/dev/null 2>&1; then
	echo "MISSING: container ${container}"
else
	docker inspect -f 'container_ip={{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container}"
fi
ip -4 -o addr show dev "${node_ifname}" || echo "WARN: node interface ${node_ifname} has no IPv4 address"
python3 - <<'PY'
import re
import subprocess
release = subprocess.check_output(["uname", "-r"], text=True).strip()
major, minor = map(int, release.split(".")[:2])
if (major, minor) < (5, 13):
    print("WARN: ONCache upstream tutorial expects Linux >= 5.13; this host runs", release)
PY
EOF
}

check_host "${SERVER_HOST}" "${SERVER_NODE_IFNAME}" "${SERVER_CONTAINER}"
check_host "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}" "${CLIENT_CONTAINER}"
