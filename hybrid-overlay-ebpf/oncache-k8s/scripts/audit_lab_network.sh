#!/usr/bin/env bash
# Audit host networking + Antrea config (find why server2 may look "down" during benchmarks).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

audit_host() {
	local host="$1"
	local phy="$2"
	local vlan="$3"
	log "======== ${host} ========"
	remote_bash "${host}" <<EOF
set -euo pipefail
echo "--- uptime / load ---"
uptime
echo "--- default route / addresses ---"
ip -4 route show default
ip -br addr | grep -E '^(enp|lo|antrea|genev|vxlan|vxnl)' || ip -br addr
echo "--- SSH listen ---"
ss -tlnp | grep ':22 ' || true
echo "--- leftover nested vxlan (should be empty) ---"
ip -br link | grep vxnl || echo "(none)"
echo "--- TC clsact on transport NICs ---"
for d in '${phy}' '${vlan}'; do
  ip link show "\$d" &>/dev/null && tc filter show dev "\$d" egress 2>/dev/null | head -5 || true
done
echo "--- iptables mangle (overlay-stress / nested) ---"
iptables -t mangle -S 2>/dev/null | grep -E '6081|4790|MARK' | head -10 || true
echo "--- kubelet / antrea-agent local ---"
systemctl is-active kubelet containerd 2>/dev/null || true
EOF
}

echo "=== Antrea ConfigMap (cluster-wide — affects server2) ==="
remote "${MASTER_HOST}" "kubectl -n kube-system get configmap antrea-config -o yaml" \
	| grep -E 'transportInterface|defaultMTU' || true

echo "=== Kubernetes nodes ==="
remote "${MASTER_HOST}" "kubectl get nodes -o wide" || true

audit_host "${SERVER_HOST}" "${SERVER_PHY_IFNAME}" "${SERVER_VLAN_IFNAME}"
audit_host "${CLIENT_HOST}" "${CLIENT_PHY_IFNAME}" "${CLIENT_VLAN_IFNAME}"

echo ""
echo "If transportInterface is enp4s0.4000 on BOTH nodes, server2 is misconfigured (needs enp1s0.4000 or use transportInterfaceCIDRs)."
echo "If vxnl* or TC mirred filters exist, run: ./scripts/teardown_nested_vxlan.sh 2>/dev/null || manual tc qdisc del"
