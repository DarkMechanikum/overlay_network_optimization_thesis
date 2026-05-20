#!/usr/bin/env python3
"""Dump flow_stats entries from the attached TC eBPF program."""

from __future__ import annotations

import argparse
import json
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bpf_maps import bpftool_prefix, resolve_attached_maps


COUNTER_NAMES = {
    0: "CNT_TOTAL_PACKETS",
    1: "CNT_PARSED_IPV4",
    2: "CNT_PARSED_TCP",
    3: "CNT_PARSED_UDP",
    4: "CNT_UNSUPPORTED_ETH",
    5: "CNT_UNSUPPORTED_IP",
    6: "CNT_FRAGMENTED_IP",
    7: "CNT_FLOW_NEW",
    8: "CNT_FLOW_SEEN",
    9: "CNT_HOT_PACKETS",
    10: "CNT_FALLBACK_PACKETS",
    11: "CNT_SAMPLE_SKIPPED",
    12: "CNT_PARSE_ERROR",
}

PROTO_NAMES = {
    socket.IPPROTO_TCP: "TCP",
    socket.IPPROTO_UDP: "UDP",
}


def run_bpftool(*args: str) -> Any:
    proc = subprocess.run([*bpftool_prefix(), *args], check=True, capture_output=True, text=True)
    return json.loads(proc.stdout or "[]")


def bytes_from_json(raw: Any) -> bytes:
    if isinstance(raw, list):
        return bytes(int(byte, 16) for byte in raw)
    if isinstance(raw, dict):
        return struct.pack(
            "<IIHHBBH",
            int(raw["src_ip"]),
            int(raw["dst_ip"]),
            int(raw["src_port"]),
            int(raw["dst_port"]),
            int(raw["proto"]),
            int(raw.get("pad1", 0)),
            int(raw.get("pad2", 0)),
        )
    return struct.pack("<I", int(raw))


def decode_flow_key(raw_key: Any) -> tuple[str, int, str, int, str]:
    packed = bytes_from_json(raw_key)
    src_ip, dst_ip, src_port, dst_port, proto = struct.unpack_from("!IIHHB", packed, 0)
    src_ip_s = socket.inet_ntoa(struct.pack("!I", src_ip))
    dst_ip_s = socket.inet_ntoa(struct.pack("!I", dst_ip))
    proto_s = PROTO_NAMES.get(proto, str(proto))
    return src_ip_s, socket.ntohs(src_port), dst_ip_s, socket.ntohs(dst_port), proto_s


def decode_flow_stats(raw_value: Any) -> dict[str, int]:
    if isinstance(raw_value, dict):
        return {
            "first_seen_ns": int(raw_value["first_seen_ns"]),
            "last_seen_ns": int(raw_value["last_seen_ns"]),
            "packets": int(raw_value["packets"]),
            "sampled_packets": int(raw_value["sampled_packets"]),
            "bytes": int(raw_value["bytes"]),
        }
    packed = bytes_from_json(raw_value)
    first_seen_ns, last_seen_ns, packets, sampled_packets, byte_count = struct.unpack(
        "<QQQQQ", packed
    )
    return {
        "first_seen_ns": first_seen_ns,
        "last_seen_ns": last_seen_ns,
        "packets": packets,
        "sampled_packets": sampled_packets,
        "bytes": byte_count,
    }


def dump_flows(map_id: int, limit: int) -> list[dict[str, Any]]:
    entries = run_bpftool("map", "dump", "id", str(map_id), "-j")
    now_ns = time.time_ns()
    rows: list[dict[str, Any]] = []

    for entry in entries:
        src_ip, src_port, dst_ip, dst_port, proto = decode_flow_key(entry["key"])
        stats = decode_flow_stats(entry["value"])
        age_ms = max(0, (now_ns - stats["first_seen_ns"]) // 1_000_000)
        last_seen_ms = max(0, (now_ns - stats["last_seen_ns"]) // 1_000_000)
        rows.append(
            {
                "src_ip": src_ip,
                "src_port": src_port,
                "dst_ip": dst_ip,
                "dst_port": dst_port,
                "proto": proto,
                "packets": stats["packets"],
                "sampled": stats["sampled_packets"],
                "bytes": stats["bytes"],
                "age_ms": age_ms,
                "last_seen_ms": last_seen_ms,
            }
        )

    rows.sort(key=lambda row: row["packets"], reverse=True)
    if limit > 0:
        return rows[:limit]
    return rows


def dump_counters(map_id: int) -> None:
    entries = run_bpftool("map", "dump", "id", str(map_id), "-j")
    for entry in entries:
        key = struct.unpack("<I", bytes_from_json(entry["key"]))[0]
        value = struct.unpack("<Q", bytes_from_json(entry["value"]))[0]
        name = COUNTER_NAMES.get(key, f"CNT_{key}")
        print(f"{name:24s} {value}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iface", help="Attached interface for map lookup")
    parser.add_argument("--limit", type=int, default=0, help="Limit number of flows printed")
    parser.add_argument("--counters", action="store_true", help="Dump global_counters instead")
    args = parser.parse_args()

    maps = resolve_attached_maps(args.iface)
    map_name = "global_counters" if args.counters else "flow_stats"
    map_id = maps[map_name]

    if args.counters:
        dump_counters(map_id)
        return 0

    rows = dump_flows(map_id, args.limit)
    header = (
        f"{'src_ip':<14}{'src_port':>8}  {'dst_ip':<14}{'dst_port':>8}  "
        f"{'proto':<5}{'packets':>8}  {'sampled':>8}  {'bytes':>10}  "
        f"{'age_ms':>8}  {'last_seen_ms':>12}"
    )
    print(header)
    for row in rows:
        print(
            f"{row['src_ip']:<14}{row['src_port']:>8}  "
            f"{row['dst_ip']:<14}{row['dst_port']:>8}  "
            f"{row['proto']:<5}{row['packets']:>8}  "
            f"{row['sampled']:>8}  {row['bytes']:>10}  "
            f"{row['age_ms']:>8}  {row['last_seen_ms']:>12}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
