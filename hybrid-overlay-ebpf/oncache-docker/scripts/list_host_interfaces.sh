#!/usr/bin/env bash
# Summarize host network interfaces (lab vs Docker vs K8s vs system).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

summarize_host() {
	local host="$1"
	log "======== ${host} ========"
	remote_bash "${host}" <<'REMOTE'
set -euo pipefail
echo "== link (all) =="
ip -br link
echo
echo "== global addresses =="
ip -br addr show scope global
echo
echo "== docker =="
docker info --format 'Swarm: {{.Swarm.LocalNodeState}}' 2>/dev/null || echo "docker unavailable"
docker ps -a --format 'container {{.Names}} {{.Status}}' 2>/dev/null || true
docker network ls 2>/dev/null || true
echo
echo "== docker netns =="
ls -la /var/run/docker/netns/ 2>/dev/null || echo "(none)"
echo
echo "== categorize =="
ip -o link show | while read -r _ idx name _ rest; do
  name="${name%:}"
  case "${name}" in
    lo|enp*) cat="system/Hetzner" ;;
    docker0) cat="Docker default bridge" ;;
    docker_gwbridge|veth*) cat="Swarm ingress / gwbridge" ;;
    gre*|bench*) cat="thesis lab" ;;
    ovs-system|genev_*|antrea-*|coredns--*) cat="Kubernetes Antrea CNI" ;;
    br-*) cat="Docker custom bridge" ;;
    vxlan*) cat="overlay tunnel (host)" ;;
    *) cat="other: $(ip -d link show "${name}" 2>/dev/null | head -1)" ;;
  esac
  printf '  %-24s %s\n' "${name}" "${cat}"
done
REMOTE
}

summarize_host "${SERVER_HOST}"
summarize_host "${CLIENT_HOST}"
