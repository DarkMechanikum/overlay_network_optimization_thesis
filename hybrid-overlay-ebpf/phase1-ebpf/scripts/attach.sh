#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=ebpf_env.sh
source "${ROOT}/scripts/ebpf_env.sh"

IFACE="${1:?Usage: $0 <iface>}"
OBJ="${2:-${ROOT}/build/flow_classifier.bpf.o}"
SEC="${3:-tc}"

if [[ ! -f "${OBJ}" ]]; then
	echo "Missing eBPF object: ${OBJ}" >&2
	echo "Run ${ROOT}/scripts/build.sh first." >&2
	exit 1
fi

maybe_sudo run_in_attach_ns tc qdisc add dev "${IFACE}" clsact 2>/dev/null || true
maybe_sudo run_in_attach_ns tc filter replace dev "${IFACE}" ingress bpf da obj "${OBJ}" sec "${SEC}"

echo "Attached ${OBJ} section ${SEC} to ${IFACE} ingress"
