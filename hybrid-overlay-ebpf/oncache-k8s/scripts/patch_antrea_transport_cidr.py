#!/usr/bin/env python3
"""Remove global transportInterface; set transportInterfaceCIDRs for multi-node labs."""
import json
import re
import subprocess
import sys


def main() -> None:
    cidr = sys.argv[1] if len(sys.argv) > 1 else "168.119.133.0/24"
    raw = subprocess.check_output(
        ["kubectl", "-n", "kube-system", "get", "configmap", "antrea-config", "-o", "json"]
    )
    cm = json.loads(raw)
    lines = cm["data"]["antrea-agent.conf"].splitlines()
    out: list[str] = []
    in_cidr = False
    seen_cidr = False
    for line in lines:
        if re.match(r"^transportInterface:", line):
            continue
        if re.match(r"^transportInterfaceCIDRs:", line):
            if not seen_cidr:
                out.append("transportInterfaceCIDRs:")
                out.append(f"  - {cidr}")
                seen_cidr = True
            in_cidr = True
            continue
        if in_cidr:
            if line.startswith("  -") or (line.startswith(" ") and line.strip() and not line.strip().startswith("#")):
                continue
            in_cidr = False
        out.append(line)
    if not seen_cidr:
        out.append("transportInterfaceCIDRs:")
        out.append(f"  - {cidr}")
    cm["data"]["antrea-agent.conf"] = "\n".join(out) + "\n"
    subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(cm).encode(), check=True)
    print(f"patched transportInterfaceCIDRs={cidr}")


if __name__ == "__main__":
    main()
