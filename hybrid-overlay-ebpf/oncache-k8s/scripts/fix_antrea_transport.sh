#!/usr/bin/env bash
# Use transportInterfaceCIDRs (vSwitch) instead of a single NIC name — safe for server1 and server2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

# Hetzner vSwitch / Cloud Network — both nodes have underlay IPs here.
VSITCH_CIDR="${ANTREA_TRANSPORT_CIDR:-168.119.133.0/24}"

log "Patching Antrea: transportInterfaceCIDRs=${VSITCH_CIDR}, clear single transportInterface"

remote_bash "${MASTER_HOST}" <<EOF
set -euo pipefail
python3 - <<'PY'
import json, re, subprocess, sys

cidr = "${VSITCH_CIDR}"
raw = subprocess.check_output(
    ["kubectl", "-n", "kube-system", "get", "configmap", "antrea-config", "-o", "json"]
)
cm = json.loads(raw)
conf = cm["data"]["antrea-agent.conf"]
lines = conf.splitlines()
out = []
skip_cidr_block = False
seen_cidr = False
for line in lines:
    if re.match(r"^transportInterface:", line):
        continue  # remove global name (breaks server2 if set to enp4s0.4000)
    if re.match(r"^transportInterfaceCIDRs:", line):
        if not seen_cidr:
            out.append("transportInterfaceCIDRs:")
            out.append(f"  - {cidr}")
            seen_cidr = True
        skip_cidr_block = True
        continue
    if skip_cidr_block:
        if line.startswith("  -") or (line.startswith(" ") and not line.strip().startswith("#")):
            continue
        skip_cidr_block = False
    out.append(line)
if not seen_cidr:
    out.append("transportInterfaceCIDRs:")
    out.append(f"  - {cidr}")
cm["data"]["antrea-agent.conf"] = "\n".join(out) + "\n"
subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(cm).encode(), check=True)
PY
kubectl -n kube-system get configmap antrea-config -o yaml | grep -E 'transportInterface|defaultMTU' || true
EOF

log "Done. Restart Antrea manually if needed: kubectl -n kube-system rollout restart ds/antrea-agent"
