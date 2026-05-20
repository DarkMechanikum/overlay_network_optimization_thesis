#!/usr/bin/env bash
# Set NODE_IFNAME in ONCache daemon.py for this host.
set -euo pipefail

ONCACHE_USER_PROG="${1:?Usage: $0 <oncache-user_prog-dir> <node-ifname>}"
NODE_IFNAME="${2:?Usage: $0 <oncache-user_prog-dir> <node-ifname>}"

DAEMON="${ONCACHE_USER_PROG}/daemon.py"
if [[ ! -f "${DAEMON}" ]]; then
	echo "Missing ${DAEMON}" >&2
	exit 1
fi

python3 - "${DAEMON}" "${NODE_IFNAME}" <<'PY'
import re
import sys

path, ifname = sys.argv[1:3]
text = open(path).read()
text, n = re.subn(r'^NODE_IFNAME = ".*"$', f'NODE_IFNAME = "{ifname}"', text, count=1, flags=re.M)
if n != 1:
    raise SystemExit("NODE_IFNAME assignment not found")
open(path, "w").write(text)
print("patched", path, "NODE_IFNAME=", ifname)
PY
