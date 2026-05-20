#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

MIN_POLICIES="${OVERLAY_STRESS_POLICY_COUNT:-150}"

EXPECTED_MTU="${OVERLAY_STRESS_MTU:-1280}"
log "Verifying overlay stress (MTU + NetworkPolicies)"
for attempt in 1 2 3 4 5 6; do
	if remote_bash "${MASTER_HOST}" <<EOF
set -euo pipefail
echo "Antrea MTU:"
kubectl -n kube-system get configmap antrea-config -o yaml | grep -E 'defaultMTU:' || true
mtu=\$(kubectl -n kube-system get configmap antrea-config -o jsonpath='{.data.antrea-agent\.conf}' | grep -m1 '^defaultMTU:' | awk '{print \$2}')
echo "NetworkPolicies in ${NAMESPACE}:"
kubectl -n '${NAMESPACE}' get networkpolicy 2>/dev/null | sed -n '1,20p' || true
count=\$(kubectl -n '${NAMESPACE}' get networkpolicy --no-headers 2>/dev/null | wc -l)
echo "total policies: \${count} (mtu=\${mtu})"
test "\${mtu}" = '${EXPECTED_MTU}' && test "\${count}" -ge $((MIN_POLICIES + 1 ))
EOF
	then
		break
	fi
	log "Verify cluster state not ready (attempt ${attempt}/6), retry in 10s..."
	sleep 10
	[[ "${attempt}" -eq 6 ]] && { echo "Overlay stress verification failed (MTU/policies)." >&2; exit 1; }
done

SERVER_IP="$(kubectl_remote "get pod '${SERVER_POD}' -o jsonpath='{.status.podIP}'" 2>/dev/null || true)"
if [[ -z "${SERVER_IP}" ]]; then
	"${SCRIPT_DIR}/deploy_netperf_pods.sh" "${CONFIG_FILE}"
	SERVER_IP="$(kubectl_remote "get pod '${SERVER_POD}' -o jsonpath='{.status.podIP}'")"
fi

log "Pod MTU check"
kubectl_remote "exec '${CLIENT_POD}' -- sh -c 'ip link show eth0; cat /sys/class/net/eth0/mtu'" || true

log "TCP_RR smoke test (5s)"
kubectl_remote "exec '${SERVER_POD}' -- sh -c 'pkill netserver 2>/dev/null || true; netserver -D </dev/null >/dev/null 2>&1 & sleep 1'" || true
kubectl_remote_timeout 30 \
	"exec '${CLIENT_POD}' -- netperf -H '${SERVER_IP}' -t TCP_RR -l 5 -- -r 64,64 -o MEAN_LATENCY,TRANSACTION_RATE"
log "verify_overlay_stress: OK"
