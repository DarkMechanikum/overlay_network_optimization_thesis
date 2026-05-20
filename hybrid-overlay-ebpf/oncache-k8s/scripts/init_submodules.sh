#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ ! -d "${ONCACHE_SRC}/.git" ]]; then
	echo "ONCache source tree not found at ${ONCACHE_SRC}" >&2
	exit 1
fi

log "Initializing ONCache submodules in ${ONCACHE_SRC}"
git -C "${ONCACHE_SRC}" submodule update --init --recursive
