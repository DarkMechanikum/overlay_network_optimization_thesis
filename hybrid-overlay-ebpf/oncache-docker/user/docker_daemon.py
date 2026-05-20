#!/usr/bin/env python3
"""Attach ONCache TC programs to Docker Swarm containers on a single host."""

from __future__ import annotations

import argparse
import atexit
import os
import subprocess
import sys
import time
from pathlib import Path

import yaml


def run(cmd: list[str], *, cwd: Path | None = None, check: bool = True) -> str:
    sudo_pass = os.environ.get("ONCACHE_SUDO_PASS")
    kwargs: dict = {"cwd": cwd, "check": check, "capture_output": True, "text": True}
    if sudo_pass and cmd and "tc_prog_loader" in str(cmd[0]):
        cmd = ["sudo", "-S", "-p", ""] + cmd
        kwargs["input"] = sudo_pass + "\n"
    proc = subprocess.run(cmd, **kwargs)
    return proc.stdout.strip()


def docker_value(container: str, template: str) -> str:
    return run(["docker", "inspect", "-f", template, container])


def find_attachment(container: str, container_ifname: str, script: Path) -> dict[str, str]:
    output = run(["bash", str(script), container, container_ifname])
    values: dict[str, str] = {}
    for line in output.splitlines():
        key, value = line.split("=", 1)
        values[key] = value
    return values


def run_loader(
    loader: Path,
    oncache_dir: Path,
    *,
    dev: str,
    section: str,
    egress: bool = False,
    new_qdisc: bool = False,
    remove: bool = False,
    netns: str = "",
) -> None:
    cmd = []
    if netns:
        cmd.extend(["nsenter", f"--net={netns}"])
    cmd.append(str(loader))
    if remove:
        cmd.append("--remove")
        if egress:
            cmd.append("--egress")
        cmd.extend(["--dev", dev])
    else:
        cmd.extend(
            [
                "--dev",
                dev,
                "--filename",
                str(oncache_dir / "tc_prog" / "tc_prog_kern.o"),
                "--sec-name",
                section,
            ]
        )
        if egress:
            cmd.append("--egress")
        if new_qdisc:
            cmd.append("--new-qdisc")
    run(cmd, cwd=loader.parent)


def read_mapdata(path: Path) -> dict:
    if not path.exists():
        return {
            "ingress_cache": {},
            "devmap": {},
            "swarm_redirect": {},
            "egressip_cache": {},
            "egress_cache": {},
        }
    payload = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    payload.setdefault("ingress_cache", {})
    payload.setdefault("devmap", {})
    payload.setdefault("swarm_redirect", {})
    payload.setdefault("egressip_cache", {})
    payload.setdefault("egress_cache", {})
    return payload


def write_mapdata(
    path: Path,
    ingress_cache: dict[str, dict[str, int]],
    devmap: dict[int, dict[str, str]],
    swarm_redirect: dict[int, int] | None = None,
    egressip_cache: dict[str, str] | None = None,
    egress_cache: dict[str, dict[str, int]] | None = None,
) -> None:
    payload = {
        "ingress_cache": ingress_cache,
        "devmap": devmap,
    }
    if swarm_redirect is not None:
        payload["swarm_redirect"] = swarm_redirect
    if egressip_cache is not None:
        payload["egressip_cache"] = egressip_cache
    if egress_cache is not None:
        payload["egress_cache"] = egress_cache
    with path.open("w", encoding="utf-8") as handle:
        yaml.safe_dump(payload, handle, default_flow_style=False)


def first_ipv4(text: str) -> str:
    for line in text.splitlines():
        line = line.strip()
        if line and "." in line:
            return line.split()[0]
    return text.strip().split()[0]


class ONCacheDockerDaemon:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.oncache_dir = Path(args.oncache_dir).resolve()
        self.setup_dir = Path(args.setup_dir).resolve()
        self.user_prog = self.oncache_dir / "user_prog"
        self.loader = self.user_prog / "tc_prog_loader"
        self.set_map = self.user_prog / "set_map"
        self.attachment_script = self.setup_dir / "scripts" / "find_container_attachment.sh"
        self.configured: set[str] = set()
        self.node_ifname = args.node_ifname
        self.container_ifname = args.container_ifname
        self.enable_ovs_hooks = args.enable_ovs_hooks
        self.remote_pod_ip = os.environ.get("ONCACHE_REMOTE_POD_IP", "")
        self.remote_underlay = os.environ.get("ONCACHE_REMOTE_UNDERLAY", "")

    def init_host(self) -> None:
        run(["rm", "-rf", "/sys/fs/bpf/tc/globals/*"], check=False)
        run_loader(
            self.loader,
            self.oncache_dir,
            dev=self.node_ifname,
            section="tc_init_e",
            egress=True,
            new_qdisc=True,
        )
        ifindex = int(run(["cat", f"/sys/class/net/{self.node_ifname}/ifindex"]))
        ifmac = run(["cat", f"/sys/class/net/{self.node_ifname}/address"])
        ifip = first_ipv4(
            run(
                [
                    "bash",
                    "-lc",
                    f"ip -4 -o addr show dev {self.node_ifname} | awk '{{print $4}}' | cut -d/ -f1",
                ]
            )
        )
        write_mapdata(
            self.user_prog / "mapdata.yaml",
            {},
            {ifindex: {"ip": ifip, "mac": ifmac}},
            {},
            {},
            {},
        )
        run([str(self.set_map)], cwd=self.user_prog)

        if self.enable_ovs_hooks:
            run(["bash", "set_ovs.sh"], cwd=self.user_prog)

    def configure_container(self, container: str) -> None:
        if container in self.configured:
            return

        attachment = find_attachment(container, self.container_ifname, self.attachment_script)
        container_ip = attachment["CONTAINER_IP"]
        peer_ifindex = int(attachment["PEER_IFINDEX"])
        pid = attachment["CONTAINER_PID"]
        masq_iface = attachment["IFACE"]
        masq_netns = attachment.get("NETNS", "")
        vxlan_iface = attachment.get("VXLAN_IFACE", "")
        vxlan_ifindex = int(attachment.get("VXLAN_IFINDEX") or "0")
        local_veth = attachment.get("LOCAL_VETH_IFINDEX", "").strip()
        container_ifindex = int(
            run(
                [
                    "docker",
                    "exec",
                    container,
                    "cat",
                    f"/sys/class/net/{self.container_ifname}/ifindex",
                ]
            )
        )
        if masq_netns:
            overlay_veth_ifidx = int(local_veth) if local_veth else peer_ifindex
        else:
            overlay_veth_ifidx = container_ifindex

        run_loader(
            self.loader,
            self.oncache_dir,
            dev=self.container_ifname,
            section="tc_init_in",
            new_qdisc=True,
            netns=f"/proc/{pid}/ns/net",
        )
        if masq_netns:
            run_loader(
                self.loader,
                self.oncache_dir,
                dev=self.container_ifname,
                section="tc_masq",
                egress=True,
                new_qdisc=False,
                netns=f"/proc/{pid}/ns/net",
            )
        else:
            run_loader(
                self.loader,
                self.oncache_dir,
                dev=masq_iface,
                section="tc_masq",
                new_qdisc=False,
            )
        if masq_netns and vxlan_iface:
            run_loader(
                self.loader,
                self.oncache_dir,
                dev=vxlan_iface,
                section="tc_restore",
                new_qdisc=True,
                netns=masq_netns,
            )
        elif not masq_netns:
            run_loader(
                self.loader,
                self.oncache_dir,
                dev=self.node_ifname,
                section="tc_restore",
                new_qdisc=False,
            )

        mapdata_path = self.user_prog / "mapdata.yaml"
        payload = read_mapdata(mapdata_path)
        payload["ingress_cache"][container_ip] = {"ifidx": overlay_veth_ifidx}
        swarm_redirect = dict(payload.get("swarm_redirect", {}))
        host_nic_idx = int(run(["cat", f"/sys/class/net/{self.node_ifname}/ifindex"]))
        swarm_redirect[0] = host_nic_idx
        swarm_redirect[1] = container_ifindex
        egressip_cache = dict(payload.get("egressip_cache", {}))
        egress_cache = dict(payload.get("egress_cache", {}))
        if self.remote_pod_ip and self.remote_underlay:
            egressip_cache[self.remote_pod_ip] = self.remote_underlay
            egress_cache[self.remote_underlay] = {"ifidx": host_nic_idx}
        write_mapdata(
            mapdata_path,
            payload["ingress_cache"],
            payload["devmap"],
            swarm_redirect,
            egressip_cache,
            egress_cache,
        )
        run([str(self.set_map)], cwd=self.user_prog)
        self.configured.add(container)
        print(
            f"Configured ONCache for container {container} ({container_ip}) "
            f"masq=eth0@{container_ifindex} overlay_veth={overlay_veth_ifidx} vxlan={vxlan_iface}"
        )

    def cleanup(self) -> None:
        run(["rm", "-rf", "/sys/fs/bpf/tc/globals/*"], check=False)
        run_loader(
            self.loader,
            self.oncache_dir,
            dev=self.node_ifname,
            section="tc_init_e",
            remove=True,
            egress=True,
        )
        print("ONCache cleanup finished")

    def watch(self) -> None:
        self.init_host()
        atexit.register(self.cleanup)
        print("ONCache host init finished")
        while True:
            for container in self.args.containers:
                running = docker_value(container, "{{.State.Running}}")
                if running != "true":
                    continue
                self.configure_container(container)
            time.sleep(self.args.interval)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oncache-dir", default="/root/ONCache")
    parser.add_argument("--setup-dir", default="/root/oncache-docker")
    parser.add_argument("--node-ifname", required=True)
    parser.add_argument("--container-ifname", default="eth0")
    parser.add_argument("--containers", nargs="+", required=True)
    parser.add_argument("--interval", type=float, default=2.0)
    parser.add_argument("--enable-ovs-hooks", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    daemon = ONCacheDockerDaemon(args)
    daemon.watch()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
