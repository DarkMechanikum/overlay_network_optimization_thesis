#!/usr/bin/env bash
# Install build/docker deps with sudo (password via SUDO_PASS or first arg).
set -euo pipefail

SUDO_PASS="${SUDO_PASS:-${1:-}}"
if [[ -z "${SUDO_PASS}" ]]; then
	echo "Usage: SUDO_PASS=... $0" >&2
	exit 1
fi

run_sudo() {
	echo "${SUDO_PASS}" | sudo -S -p '' "$@"
}

export DEBIAN_FRONTEND=noninteractive
run_sudo apt-get update -qq

KVER="$(uname -r)"
PACKAGES=(
	clang llvm libelf-dev libpcap-dev gcc-multilib build-essential cmake
	python3 python3-yaml git pkg-config iproute2 linux-headers-"${KVER}"
)
if ! command -v docker >/dev/null 2>&1; then
	if dpkg -l docker-ce 2>/dev/null | awk '{print $1,$2}' | grep -q '^ii docker-ce'; then
		:
	else
		PACKAGES+=(docker.io)
	fi
fi
if ! docker compose version >/dev/null 2>&1 && ! docker-compose version >/dev/null 2>&1; then
	if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
		PACKAGES+=(docker-compose-plugin)
	fi
fi
if apt-cache policy bpftool 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -qv '(none)'; then
	PACKAGES+=(bpftool)
else
	PACKAGES+=(linux-tools-common "linux-tools-${KVER}")
fi
run_sudo apt-get install -y -qq "${PACKAGES[@]}"

run_sudo usermod -aG docker "$(whoami)" 2>/dev/null || true
run_sudo systemctl enable --now docker 2>/dev/null || true

if ! mountpoint -q /sys/fs/bpf; then
	run_sudo mkdir -p /sys/fs/bpf
	run_sudo mount -t bpf bpf /sys/fs/bpf
fi

echo "Dependencies installed on $(hostname)"
