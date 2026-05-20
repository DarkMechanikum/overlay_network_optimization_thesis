#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

OVERLAY_STRESS_RESTORE_MTU="${OVERLAY_STRESS_RESTORE_MTU:-1450}"

log "Removing overlay stress policies and restoring MTU=${OVERLAY_STRESS_RESTORE_MTU}"

remote_bash "${MASTER_HOST}" <<EOF
set -euo pipefail
NS='${NAMESPACE}'
MTU='${OVERLAY_STRESS_RESTORE_MTU}'

kubectl -n "\${NS}" get networkpolicy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | \\
  grep '^overlay-stress' | xargs -r -I{} kubectl -n "\${NS}" delete networkpolicy {} --ignore-not-found=true || true

python3 "${REMOTE_SETUP_DIR}/scripts/patch_antrea_mtu.py" '${OVERLAY_STRESS_RESTORE_MTU}'
kubectl -n kube-system rollout restart daemonset/antrea-agent
kubectl -n kube-system rollout status daemonset/antrea-agent --timeout=300s
EOF

log "Overlay stress removed"
