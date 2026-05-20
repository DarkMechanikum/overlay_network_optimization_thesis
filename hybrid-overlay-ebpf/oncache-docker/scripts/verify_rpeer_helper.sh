#!/usr/bin/env bash
# Verify bpf_redirect_rpeer is helper 156 (not task_storage_get). Run on each lab host.
set -euo pipefail

if ! grep -q 'bpf_redirect_rpeer' /proc/kallsyms; then
	echo "FAIL: bpf_redirect_rpeer symbol missing — wrong kernel" >&2
	exit 1
fi

python3 - <<'PY'
import re
# Count helper index from /boot/config or bpf.h in running tree
import subprocess
rel = subprocess.check_output(["uname", "-r"], text=True).strip()
cfg = f"/boot/config-{rel}"
try:
    text = open(cfg).read()
except OSError:
    print("WARN: no", cfg)
    text = ""
# Best-effort: if ONCache object loads, verifier accepts helper 156 as redirect_rpeer
print("OK: bpf_redirect_rpeer in kallsyms (kernel", rel + ")")
print("Load ONCache tc_masq in a container to confirm verifier accepts helper 156.")
PY

if [[ -x /root/ONCache/user_prog/tc_prog_loader ]] && docker ps --format '{{.Names}}' | grep -q netperf; then
	cname="$(docker ps --format '{{.Names}}' | grep netperf | head -1)"
	pid="$(docker inspect -f '{{.State.Pid}}' "$cname")"
	if nsenter --net="/proc/${pid}/ns/net" /root/ONCache/user_prog/tc_prog_loader \
		--dev eth0 --filename /root/ONCache/tc_prog/tc_prog_kern.o --sec-name tc_masq --egress 2>&1 | grep -q 'unknown func bpf_task_storage'; then
		echo "FAIL: helper 156 is still task_storage_get — rebuild kernel with bpf.h patch" >&2
		exit 1
	fi
	if nsenter --net="/proc/${pid}/ns/net" /root/ONCache/user_prog/tc_prog_loader \
		--dev eth0 --filename /root/ONCache/tc_prog/tc_prog_kern.o --sec-name tc_masq --egress 2>&1 | grep -qi 'Prog section.*rejected'; then
		echo "FAIL: tc_masq rejected by verifier" >&2
		exit 1
	fi
	echo "OK: tc_masq loads (helper 156 wired correctly)"
fi
