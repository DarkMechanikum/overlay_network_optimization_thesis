#!/usr/bin/env bash
# Synthetic overlay load: lower Antrea MTU + many NetworkPolicies (OVS policy evaluation).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

OVERLAY_STRESS_MTU="${OVERLAY_STRESS_MTU:-1280}"
OVERLAY_STRESS_POLICY_COUNT="${OVERLAY_STRESS_POLICY_COUNT:-150}"
OVERLAY_STRESS_RESTORE_MTU="${OVERLAY_STRESS_RESTORE_MTU:-1450}"
MANIFEST_DIR="${SETUP_ROOT}/manifests/overlay-stress"

log "Applying overlay stress: MTU=${OVERLAY_STRESS_MTU} policies=${OVERLAY_STRESS_POLICY_COUNT}"

python3 - "${MANIFEST_DIR}" "${NAMESPACE}" "${OVERLAY_STRESS_POLICY_COUNT}" <<'PY'
import os, sys, pathlib

out = pathlib.Path(sys.argv[1])
ns = sys.argv[2]
count = int(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)

deny = f"""apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: overlay-stress-deny-all
  namespace: {ns}
spec:
  podSelector: {{}}
  policyTypes: [Ingress, Egress]
"""
(out / "00-deny-all.yaml").write_text(deny)

chunks = []
for i in range(count):
    o1 = (i % 200) + 1
    o2 = ((i // 200) % 200) + 1
    doc = f"""apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: overlay-stress-{i:04d}
  namespace: {ns}
spec:
  podSelector:
    matchExpressions:
    - key: app
      operator: In
      values: [netperf-server, netperf-client]
  policyTypes: [Ingress, Egress]
  ingress:
  - from:
    - ipBlock:
        cidr: 10.{o1}.{o2}.0/24
    ports:
    - protocol: TCP
      port: 59999
  - from:
    - podSelector:
        matchLabels:
          app: netperf-client
    ports:
    - protocol: TCP
      port: 12865
  egress:
  - to:
    - ipBlock:
        cidr: 10.{o1}.{o2}.0/24
    ports:
    - protocol: TCP
      port: 59999
  - to:
    - podSelector:
        matchLabels:
          app: netperf-client
  - to:
    - podSelector:
        matchLabels:
          app: netperf-server
    ports:
    - protocol: TCP
      port: 12865
"""
    chunks.append(doc)

# Batch into fewer files for faster kubectl apply
batch = 20
for b in range(0, len(chunks), batch):
    (out / f"policies-{b:04d}.yaml").write_text("---\n".join(chunks[b : b + batch]))
print(f"Wrote {count} policies + deny-all under {out}")
PY

remote "${MASTER_HOST}" "mkdir -p '${REMOTE_SETUP_DIR}/manifests/overlay-stress'"
rsync -az --delete "${MANIFEST_DIR}/" "${MASTER_HOST}:${REMOTE_SETUP_DIR}/manifests/overlay-stress/"

remote_bash "${MASTER_HOST}" <<EOF
set -euo pipefail
MTU='${OVERLAY_STRESS_MTU}'
RESTORE='${OVERLAY_STRESS_RESTORE_MTU}'
NS='${NAMESPACE}'
REMOTE_MAN='${REMOTE_SETUP_DIR}/manifests/overlay-stress'

echo "Saving prior MTU marker"
kubectl -n kube-system get configmap antrea-config -o yaml | grep -E 'defaultMTU:' > /tmp/oncache_prior_mtu.txt 2>/dev/null || true

# Avoid server1-only transportInterface (enp4s0.4000) breaking server2 — use vSwitch CIDR.
python3 "${REMOTE_SETUP_DIR}/scripts/patch_antrea_transport_cidr.py" '${SERVER_UNDERLAY%.*}.0/24'

python3 "${REMOTE_SETUP_DIR}/scripts/patch_antrea_mtu.py" '${OVERLAY_STRESS_MTU}'
kubectl -n kube-system get configmap antrea-config -o yaml | grep -E 'defaultMTU:|transportInterface' || true

echo "Applying NetworkPolicies (before Antrea restart — node stays reachable if rollout stalls)"
kubectl -n "\${NS}" get networkpolicy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | \\
  grep '^overlay-stress' | xargs -r -I{} kubectl -n "\${NS}" delete networkpolicy {} --ignore-not-found=true || true
for f in "\${REMOTE_MAN}"/00-deny-all.yaml "\${REMOTE_MAN}"/policies-*.yaml; do
  [[ -f "\$f" ]] && kubectl apply -f "\$f"
done
echo "NetworkPolicy count:"
kubectl -n "\${NS}" get networkpolicy --no-headers 2>/dev/null | wc -l

echo "Rolling Antrea agents (may take several minutes; SSH to public IPs should stay up)"
kubectl -n kube-system rollout restart daemonset/antrea-agent
if ! kubectl -n kube-system rollout status daemonset/antrea-agent --timeout=300s; then
  echo "WARN: Antrea rollout did not finish in 300s — check node2; continuing anyway" >&2
  kubectl -n kube-system get pods -l app=antrea-agent -o wide || true
fi

echo "Recreating netperf pods to pick up MTU"
kubectl -n "\${NS}" delete pod netperf-server netperf-client --ignore-not-found=true --wait=false --grace-period=10
sleep 5
kubectl -n "\${NS}" delete pod netperf-server netperf-client --ignore-not-found=true --force --grace-period=0 2>/dev/null || true
EOF

"${SCRIPT_DIR}/deploy_netperf_pods.sh" "${CONFIG_FILE}"

log "Overlay stress applied"
