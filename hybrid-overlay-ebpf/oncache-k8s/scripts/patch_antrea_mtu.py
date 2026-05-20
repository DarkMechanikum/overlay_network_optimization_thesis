#!/usr/bin/env python3
"""Patch antrea-agent.conf defaultMTU in antrea-config ConfigMap (single key)."""
import json
import re
import subprocess
import sys


def main() -> None:
    mtu = sys.argv[1]
    raw = subprocess.check_output(
        ["kubectl", "-n", "kube-system", "get", "configmap", "antrea-config", "-o", "json"]
    )
    cm = json.loads(raw)
    conf = cm["data"]["antrea-agent.conf"]
    lines = conf.splitlines()
    out: list[str] = []
    seen = False
    for line in lines:
        if re.match(r"^defaultMTU:", line):
            if not seen:
                out.append(f"defaultMTU: {mtu}")
                seen = True
            continue
        out.append(line)
    if not seen:
        out.append(f"defaultMTU: {mtu}")
    cm["data"]["antrea-agent.conf"] = "\n".join(out) + "\n"
    subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(cm).encode(), check=True)


if __name__ == "__main__":
    main()
