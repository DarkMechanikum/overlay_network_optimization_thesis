#!/usr/bin/env bash
# Report Hetzner vSwitch / cloud-network readiness for ipvlan underlay routing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

SERVER_UNDERLAY="${SERVER_UNDERLAY:-168.119.133.106}"
CLIENT_UNDERLAY="${CLIENT_UNDERLAY:-168.119.133.107}"

fail=0

check_host() {
	local host="$1"
	local underlay="$2"
	local peer="$3"
	local node_ifname="$4"

	log "=== ${host} (underlay ${underlay}) ==="
	remote "${host}" "bash -s" -- "${underlay}" "${peer}" "${node_ifname}" <<'REMOTE'
set -euo pipefail
underlay="$1"
peer="$2"
node_ifname="$3"

echo "-- addresses on lo matching underlay --"
ip -4 -o addr show dev lo | awk '{print $4}' | grep -E '^10\.0\.(2|3)\.' || echo "(none)"

echo "-- cloud/private NICs (NO_CARRIER highlighted) --"
for d in $(ls /sys/class/net 2>/dev/null | grep -E '^enp' | sort); do
  state="$(cat "/sys/class/net/${d}/operstate" 2>/dev/null || echo unknown)"
  carrier="$(cat "/sys/class/net/${d}/carrier" 2>/dev/null || echo ?)"
  addrs="$(ip -4 -o addr show dev "${d}" 2>/dev/null | awk '{print $4}' | paste -sd, - || true)"
  echo "  ${d}: operstate=${state} carrier=${carrier} addrs=${addrs:-none}"
done

echo "-- node NIC (${node_ifname}) --"
ip -br addr show dev "${node_ifname}" 2>/dev/null || echo "missing ${node_ifname}"

echo "-- ping peer underlay ${peer} --"
if ping -c 2 -W 2 "${peer}" >/dev/null 2>&1; then
  echo "  OK: reachable"
else
  echo "  FAIL: not reachable"
  exit 10
fi
REMOTE
}

log "vSwitch underlay check (${SERVER_UNDERLAY} <-> ${CLIENT_UNDERLAY})"
if check_host "${SERVER_HOST}" "${SERVER_UNDERLAY}" "${CLIENT_UNDERLAY}" "${SERVER_NODE_IFNAME}"; then
	log "${SERVER_HOST}: underlay OK"
else
	log "${SERVER_HOST}: underlay FAILED"
	fail=1
fi

if check_host "${CLIENT_HOST}" "${CLIENT_UNDERLAY}" "${SERVER_UNDERLAY}" "${CLIENT_NODE_IFNAME}"; then
	log "${CLIENT_HOST}: underlay OK"
else
	log "${CLIENT_HOST}: underlay FAILED"
	fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
	log ""
	log "vSwitch is not usable yet. Common fixes on Hetzner:"
	log "  1. Attach the Cloud Network to both servers; use the private NIC (carrier=1), not loopback."
	log "  2. Move ${SERVER_UNDERLAY} and ${CLIENT_UNDERLAY} from lo to that NIC (/24 or routed /32 on the private link)."
	log "  3. Remove onlink routes via the public /32 when the private link is up."
	log "  Until then, ipvlan setup will use GRE (gre-oncache) with SNAT via the public NIC for return delivery."
	exit 1
fi

log "vSwitch underlay is reachable — ipvlan routes will prefer it over GRE."
