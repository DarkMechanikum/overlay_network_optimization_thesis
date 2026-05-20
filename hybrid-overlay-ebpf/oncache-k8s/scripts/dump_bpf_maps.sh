#!/usr/bin/env bash
# Dump pinned ONCache TC maps (works on custom rpeer kernels without linux-tools match).
set -euo pipefail

PIN_DIR="${1:-/sys/fs/bpf/tc/globals}"
ONCACHE_USER="${2:-/root/ONCache/user_prog}"

g++ -O2 -o /tmp/oncache_dump_maps "${ONCACHE_USER}/dump_maps.cpp" \
	"${ONCACHE_USER}/common_user.c" \
	-I"${ONCACHE_USER}" -I"${ONCACHE_USER}/../common" -I"${ONCACHE_USER}/../headers" \
	-L"${ONCACHE_USER}/../libbpf/src" -lbpf -lelf -lz

/tmp/oncache_dump_maps "${PIN_DIR}"
