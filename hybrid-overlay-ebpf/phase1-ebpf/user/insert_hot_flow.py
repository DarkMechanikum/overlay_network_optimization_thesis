#!/usr/bin/env python3
"""Insert a flow into the hot_flows map for Phase 1 validation."""

from __future__ import annotations

import argparse
import socket
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bpf_maps import bpftool_prefix, resolve_attached_maps


def run_bpftool(*args: str) -> str:
    proc = subprocess.run([*bpftool_prefix(), *args], check=True, capture_output=True, text=True)
    return proc.stdout


def pack_flow_key(src_ip: str, dst_ip: str, src_port: int, dst_port: int, proto: int) -> bytes:
    return struct.pack(
        "!IIHHBBH",
        struct.unpack("!I", socket.inet_aton(src_ip))[0],
        struct.unpack("!I", socket.inet_aton(dst_ip))[0],
        socket.htons(src_port),
        socket.htons(dst_port),
        proto,
        0,
        0,
    )


def pack_hot_flow_value(estimated_pps: int, updated_ns: int) -> bytes:
    return struct.pack("<QQ", estimated_pps, updated_ns)


def hex_bytes(data: bytes) -> list[str]:
    return [f"{byte:02x}" for byte in data]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iface", help="Attached interface for map lookup")
    parser.add_argument("--src-ip", required=True)
    parser.add_argument("--dst-ip", required=True)
    parser.add_argument("--src-port", type=int, required=True)
    parser.add_argument("--dst-port", type=int, required=True)
    parser.add_argument("--proto", default="tcp", choices=["tcp", "udp"])
    parser.add_argument("--estimated-pps", type=int, default=1000)
    args = parser.parse_args()

    proto = socket.IPPROTO_TCP if args.proto == "tcp" else socket.IPPROTO_UDP
    key = pack_flow_key(args.src_ip, args.dst_ip, args.src_port, args.dst_port, proto)
    value = pack_hot_flow_value(args.estimated_pps, 0)
    map_id = resolve_attached_maps(args.iface)["hot_flows"]

    run_bpftool(
        "map",
        "update",
        "id",
        str(map_id),
        "key",
        "hex",
        *hex_bytes(key),
        "value",
        "hex",
        *hex_bytes(value),
    )
    print(f"Inserted hot flow into map id {map_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
