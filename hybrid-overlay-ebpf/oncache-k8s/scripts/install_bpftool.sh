#!/usr/bin/env bash
# Install a bpftool binary that works with custom rpeer kernels (no linux-tools-* match).
set -euo pipefail

if command -v bpftool >/dev/null 2>&1 && bpftool version 2>/dev/null | grep -q '^bpftool'; then
	if bpftool map show >/dev/null 2>&1; then
		exit 0
	fi
fi

if [[ -x /usr/local/bin/bpftool ]]; then
	ln -sf /usr/local/bin/bpftool /usr/sbin/bpftool 2>/dev/null || true
	exit 0
fi

apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates git make clang llvm libelf-dev libcap-dev 2>/dev/null || true

TMP="${TMPDIR:-/tmp}/bpftool-build-$$"
trap 'rm -rf "$TMP"' EXIT
git clone --recursive --depth 1 --branch v7.4.0 https://github.com/libbpf/bpftool.git "$TMP" 2>/dev/null \
	|| git clone --recursive --depth 1 https://github.com/libbpf/bpftool.git "$TMP"
make -C "$TMP/src" -j"$(nproc)" V=1
test -x "$TMP/src/bpftool"
install -m 0755 "$TMP/src/bpftool" /usr/local/bin/bpftool
ln -sf /usr/local/bin/bpftool /usr/sbin/bpftool 2>/dev/null || true
bpftool version | head -1
