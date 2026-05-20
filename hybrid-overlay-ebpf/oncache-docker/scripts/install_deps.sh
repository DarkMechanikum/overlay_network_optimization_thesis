#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
KVER="$(uname -r)"
PACKAGES=(
	clang llvm libelf-dev libpcap-dev gcc-multilib build-essential cmake
	python3 python3-yaml git pkg-config iproute2 linux-headers-"${KVER}"
)
if apt-cache show bpftool >/dev/null 2>&1; then
	PACKAGES+=(bpftool)
else
	PACKAGES+=(linux-tools-common "linux-tools-${KVER}")
fi
apt-get install -y -qq "${PACKAGES[@]}"

if ! mountpoint -q /sys/fs/bpf; then
	mkdir -p /sys/fs/bpf
	mount -t bpf bpf /sys/fs/bpf
fi

echo "ONCache build dependencies installed on $(hostname)"
