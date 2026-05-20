#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=ebpf_env.sh
source "${ROOT}/scripts/ebpf_env.sh"

IFACE="${1:?Usage: $0 <iface>}"

maybe_sudo run_in_attach_ns tc filter del dev "${IFACE}" ingress 2>/dev/null || true
maybe_sudo run_in_attach_ns tc qdisc del dev "${IFACE}" clsact 2>/dev/null || true

echo "Detached TC filters from ${IFACE}"
