#!/usr/bin/env bash
# Build Ubuntu 5.15 kernel with ONCache bpf_redirect_rpeer patch (requires reboot).
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run as root on each lab host." >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive
KVER="$(uname -r)"
PATCH_ROOT="${ONCACHE_DIR:-/root/ONCache}/rpeer_kernel_patch"
SRC_DIR="/usr/src"
MARKER="${SRC_DIR}/.oncache-rpeer-built-${KVER}"

if [[ -f "${MARKER}" ]]; then
	echo "Kernel packages already built for ${KVER}; see ${SRC_DIR}/linux-image-*-oncache-rpeer_*.deb"
	ls -1 "${SRC_DIR}"/linux-image-*-oncache-rpeer_*.deb 2>/dev/null || true
	exit 0
fi

if ! grep -rq '^[^#].*deb-src' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
	sed -i 's/^# deb-src \(.* jammy \)/deb-src \1/' /etc/apt/sources.list || true
fi

apt-get update -qq
apt-get install -y build-essential flex bison libssl-dev libelf-dev bc rsync \
	libbpf-dev dwarves python3 devscripts

KABI_PKG="linux-image-unsigned-${KVER}"
if ! apt-cache show "${KABI_PKG}" >/dev/null 2>&1; then
	KABI_PKG="linux-image-unsigned-${KVER%%-*}-generic"
fi

cd "${SRC_DIR}"
DSC="$(ls -1 "${SRC_DIR}"/linux_*.dsc 2>/dev/null | sort -V | tail -1 || true)"
if [[ -z "${DSC}" ]]; then
	echo "Unpacking source for ${KABI_PKG}"
	apt-get source "${KABI_PKG}"
	DSC="$(ls -1 "${SRC_DIR}"/linux_*.dsc 2>/dev/null | sort -V | tail -1)"
fi
shopt -s nullglob
patched_dirs=("${SRC_DIR}"/linux-5.15.0-*)
shopt -u nullglob
if ((${#patched_dirs[@]} == 0)) && [[ -n "${DSC}" ]]; then
	out="${SRC_DIR}/linux-5.15.0-patched"
	rm -rf "${out}"
	dpkg-source -x "${DSC}" "${out}"
	patched_dirs=("${out}")
fi
if ((${#patched_dirs[@]} == 0)); then
	echo "No patched linux-5.15.0-* tree under ${SRC_DIR}" >&2
	exit 1
fi
WORK="$(printf '%s\n' "${patched_dirs[@]}" | sort -V | tail -1)"
cd "${WORK}"
chmod +x scripts/*.sh 2>/dev/null || true

FILTER="${WORK}/net/core/filter.c"
PATCH_FILTER="${PATCH_ROOT}/net/core/filter.c"
APPLY="${ONCACHE_SETUP_DIR:-/root/oncache-docker}/scripts/apply_rpeer_patch.py"
if [[ ! -f "${APPLY}" ]]; then
	APPLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply_rpeer_patch.py"
fi
if ! grep -q BPF_F_RPEER "${FILTER}"; then
	cp -a "${FILTER}" "${FILTER}.bak.oncache"
	python3 "${APPLY}" "${FILTER}" "${PATCH_FILTER}"
fi

cp "/boot/config-${KVER}" .config
make olddefconfig
make -j"$(nproc)" bindeb-pkg LOCALVERSION=-oncache-rpeer
touch "${MARKER}"
echo "Built packages:"
ls -1 "${SRC_DIR}"/linux-image-*-oncache-rpeer_*.deb "${SRC_DIR}"/linux-headers-*-oncache-rpeer_*.deb
echo "Install: dpkg -i ${SRC_DIR}/linux-image-*-oncache-rpeer_*.deb ${SRC_DIR}/linux-headers-*-oncache-rpeer_*.deb && reboot"
