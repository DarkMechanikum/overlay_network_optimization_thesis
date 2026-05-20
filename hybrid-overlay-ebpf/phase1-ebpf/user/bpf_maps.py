#!/usr/bin/env python3
"""Resolve attached TC program maps on legacy and BTF-loaded objects."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from typing import Any


def bpftool_prefix() -> list[str]:
    netns = os.environ.get("NETNS", "").strip()
    prefix: list[str] = []
    if os.geteuid() != 0:
        prefix.append("sudo")
    if netns:
        prefix.extend(["nsenter", f"--net={netns}"])
    prefix.append(shutil.which("bpftool") or "/usr/sbin/bpftool")
    return prefix


def run_bpftool(*args: str) -> str:
    proc = subprocess.run([*bpftool_prefix(), *args], check=True, capture_output=True, text=True)
    return proc.stdout


def run_bpftool_json(*args: str) -> Any:
    return json.loads(run_bpftool(*args, "-j") or "[]")


def first_json_entry(payload: Any) -> dict[str, Any]:
    if isinstance(payload, list):
        return payload[0]
    return payload


def get_attached_prog_id(iface: str) -> int:
    output = run_bpftool("net", "show", "dev", iface)
    match = re.search(r"id\s+(\d+)\s*$", output, re.MULTILINE)
    if not match:
        raise RuntimeError(f"No attached bpf program found on {iface}")
    return int(match.group(1))


def classify_map(map_info: dict[str, Any]) -> str | None:
    key_size = int(map_info["bytes_key"])
    value_size = int(map_info["bytes_value"])
    map_type = map_info["type"]

    if map_type == "array" and key_size == 4 and value_size == 8:
        return "global_counters"
    if map_type == "lru_hash" and key_size == 16 and value_size == 40:
        return "flow_stats"
    if map_type == "lru_hash" and key_size == 16 and value_size == 16:
        return "hot_flows"
    return None


def resolve_attached_maps(iface: str | None) -> dict[str, int]:
    if iface:
        try:
            prog_id = get_attached_prog_id(iface)
            prog = first_json_entry(run_bpftool_json("prog", "show", "id", str(prog_id)))
            resolved: dict[str, int] = {}
            for map_id in prog["map_ids"]:
                map_info = first_json_entry(run_bpftool_json("map", "show", "id", str(map_id)))
                name = classify_map(map_info)
                if name:
                    resolved[name] = int(map_id)
            if resolved:
                return resolved
        except (RuntimeError, subprocess.CalledProcessError, IndexError, KeyError):
            pass

    resolved: dict[str, int] = {}
    for map_name in ("global_counters", "flow_stats", "hot_flows"):
        try:
            maps = run_bpftool_json("map", "show", "name", map_name)
        except subprocess.CalledProcessError:
            continue
        if maps:
            resolved[map_name] = int(first_json_entry(maps)["id"])
    if not resolved:
        raise RuntimeError("Could not resolve attached eBPF maps")
    return resolved
