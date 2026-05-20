#!/usr/bin/env bash
# DEPRECATED: single transportInterface breaks server2. Use fix_antrea_transport.sh instead.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "ensure_antrea_transport.sh is deprecated (set enp4s0.4000 on all nodes)." >&2
echo "Use: ${SCRIPT_DIR}/fix_antrea_transport.sh" >&2
exec "${SCRIPT_DIR}/fix_antrea_transport.sh" "$@"
