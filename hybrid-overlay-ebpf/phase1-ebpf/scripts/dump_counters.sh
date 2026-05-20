#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IFACE="${1:-}"

exec python3 "${ROOT}/user/dump_flows.py" --counters ${IFACE:+--iface "${IFACE}"}
