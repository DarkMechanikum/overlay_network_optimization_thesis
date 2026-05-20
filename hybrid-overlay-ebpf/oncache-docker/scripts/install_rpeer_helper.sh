#!/usr/bin/env bash
# Install bpf_redirect_rpeer (helper 156) into the running kernel's net/core/filter.c
# by patching linux-headers and rebuilding the net module. Requires reboot if module
# is built-in; on Ubuntu HWE with loadable net.ko this may work after modprobe -r net.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run as root on each lab host." >&2
	exit 1
fi

KVER="$(uname -r)"
HDR="/usr/src/linux-headers-${KVER}"
PATCH_ROOT="${ONCACHE_DIR:-/root/ONCache}/rpeer_kernel_patch"

if [[ ! -d "${HDR}" ]]; then
	echo "Install headers: apt-get install -y linux-headers-${KVER}" >&2
	exit 1
fi

FILTER="${HDR}/net/core/filter.c"
if [[ ! -f "${FILTER}" ]]; then
	echo "Missing ${FILTER}" >&2
	exit 1
fi

if grep -q 'BPF_F_RPEER' "${FILTER}"; then
	echo "Kernel headers already contain bpf_redirect_rpeer (BPF_F_RPEER)"
	exit 0
fi

cp -a "${FILTER}" "${FILTER}.bak.oncache"
cp "${PATCH_ROOT}/net/core/filter.c" "${FILTER}.oncache.patch"
python3 <<'PY' "${FILTER}" "${PATCH_ROOT}/net/core/filter.c"
import sys
dst_path, src_path = sys.argv[1:3]
# Apply only the rpeer-related hunks by copying known symbols from patch file into dst.
# Minimal approach: if patch file is full filter.c from 5.14, splice BPF_F_RPEER block.
src = open(src_path).read()
dst = open(dst_path).read()
if 'BPF_F_RPEER' not in src:
    raise SystemExit('patch source missing BPF_F_RPEER')
if 'BPF_F_RPEER' in dst:
    raise SystemExit('already patched')
# Insert enum flag after BPF_F_PEER block in dst
needle = 'BPF_F_PEER = (1ULL << 3),'
if needle not in dst:
    raise SystemExit('unexpected filter.c layout')
dst = dst.replace(
    needle,
    needle + '\n\tBPF_F_RPEER = (1ULL << 4),',
    1,
)
# Insert skb_do_redirect rpeer branch from patch (simplified marker-based)
start = src.find('if (flags & BPF_F_RPEER)')
end = src.find('} else {', start)
block = src[start:end]
marker = '\tdev = dev_get_by_index_rcu(net, tgt_index);'
if marker not in dst:
    raise SystemExit('marker not found in dst')
dst = dst.replace(
    marker,
    block + '\n\t} else {\n\t\t' + marker.lstrip(),
    1,
)
# Add bpf_redirect_rpeer function and proto registration - copy from patch if missing
if 'bpf_redirect_rpeer' not in dst:
    fn_start = src.find('BPF_CALL_2(bpf_redirect_rpeer')
    fn_end = src.find('static const struct bpf_func_proto bpf_redirect_rpeer_proto', fn_start)
    fn_end = src.find('};', fn_end) + 2
    insert_at = dst.find('static const struct bpf_func_proto bpf_redirect_peer_proto')
    if insert_at < 0:
        raise SystemExit('insert point missing')
    dst = dst[:insert_at] + src[fn_start:fn_end] + '\n\n' + dst[insert_at:]
open(dst_path, 'w').write(dst)
print('Patched', dst_path)
PY

echo "Rebuilding net module (this can take several minutes)..."
make -C "${HDR}" M=net modules -j"$(nproc)"

MOD="/lib/modules/${KVER}/kernel/net/net.ko"
if [[ -f "${MOD}" ]]; then
	cp -a "${MOD}" "${MOD}.bak.oncache"
fi
make -C "${HDR}" M=net modules_install
depmod -a
echo "Built patched net module. Reboot the host or reload net.ko if your distro allows it."
echo "Verify with: bpftool feature probe kernel | grep redirect_rpeer"
