# Phase 1: Passive eBPF Flow Telemetry

Passive TC ingress telemetry for container traffic. The program parses Ethernet, IPv4, TCP, and UDP headers, tracks per-flow counters in eBPF maps, and always returns `TC_ACT_OK` so packets are not modified.

## Layout

```text
phase1-ebpf/
├── ebpf/
│   ├── common.h
│   └── flow_classifier.bpf.c
├── scripts/
│   ├── build.sh
│   ├── find_container_veth.sh
│   ├── attach.sh
│   ├── detach.sh
│   ├── show_tc.sh
│   ├── dump_counters.sh
│   └── dump_maps.sh
├── user/
│   └── dump_flows.py
└── README.md
```

## Build

Host packages (Debian/Ubuntu example):

```bash
sudo apt install -y clang llvm make gcc iproute2 bpftool linux-headers-$(uname -r)
```

Build the object:

```bash
./scripts/build.sh
```

Optional approximate sampling (`1/8`):

```bash
SAMPLE_DIVISOR=8 ./scripts/build.sh
```

## Attach

Find the host-side veth for a container:

```bash
./scripts/find_container_veth.sh netperf-client
```

Attach to ingress:

```bash
./scripts/attach.sh <veth>
./scripts/show_tc.sh <veth>
```

Detach:

```bash
./scripts/detach.sh <veth>
```

## Inspect telemetry

```bash
./scripts/dump_counters.sh <veth>
./user/dump_flows.py --iface <veth>
./scripts/dump_maps.sh flow_stats <veth>
```

Flow keys keep IPv4 addresses and ports in network byte order. `dump_flows.py` prints host-endian ports and dotted-quad addresses.

## Notes

- `flow_stats` and `hot_flows` are LRU hash maps.
- `hot_flows` is consulted on every sampled packet; Phase 1 does not populate it automatically.
- Rebuild with `SAMPLE_DIVISOR=8` after validating exact counting.
