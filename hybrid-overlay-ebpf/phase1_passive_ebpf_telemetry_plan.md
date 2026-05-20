# Phase 1 Development Plan: Passive eBPF Flow Telemetry

## 1. Purpose

This document describes **Phase 1** of the overlay-network optimization project.

The goal of Phase 1 is to build a **passive eBPF telemetry prototype** that observes container-to-container traffic, extracts flow information, and exposes flow statistics to userspace.

Phase 1 must **not modify packet behavior**. It must not redirect, drop, rewrite, or accelerate packets. Every packet must continue through the normal Linux/Docker networking path.

The objective is to prove that we can:

- attach an eBPF program to the correct packet path,
- observe Docker/container traffic,
- parse Ethernet + IPv4 + TCP/UDP packets,
- extract the 5-tuple of each flow,
- update per-flow counters in eBPF maps,
- distinguish long-lived hot-flow-like traffic from short-lived cold-flow-like traffic,
- expose useful telemetry to userspace with acceptable overhead.

The output of this phase is the foundation for the later Top-K hot-flow cache and hybrid fast-path/fallback-path optimization.

---

## 2. High-Level Goal

Build a TC eBPF program that:

1. attaches to a Docker/container-related network interface,
2. observes packets passively,
3. parses Ethernet, IPv4, TCP, and UDP headers,
4. extracts the 5-tuple,
5. updates per-flow counters in an eBPF map,
6. updates global counters for debugging,
7. optionally samples packets,
8. optionally checks whether a flow exists in a `hot_flows` map,
9. always returns `TC_ACT_OK`.

The eBPF program must be safe and non-invasive:

```c
return TC_ACT_OK;
```

This means every packet continues normally.

---

## 3. Scope of Phase 1

### 3.1 Included

Phase 1 includes:

- TC eBPF attachment,
- packet parsing,
- flow key extraction,
- eBPF map design,
- passive packet counters,
- flow statistics collection,
- optional packet sampling,
- basic hot/fallback classification counters,
- scripts for build, attach, detach, and debugging,
- tests with Docker containers and `netperf` traffic.

### 3.2 Excluded

Phase 1 does **not** include:

- packet redirection,
- packet dropping,
- VXLAN header rewriting,
- ONCache-style fast-path encapsulation/decapsulation,
- Falcon-style softirq pipelining,
- userspace Top-K controller,
- real cache admission/eviction policy,
- production-ready performance optimization.

These are later phases.

---

## 4. Target Environment

The expected development environment is:

- two Linux hosts,
- Docker Swarm overlay network,
- one server container on host 1,
- one client container on host 2,
- `netperf` / `netserver` available in the containers,
- kernel around Linux 5.4,
- TC and eBPF tooling installed on the host.

Useful host tools:

```bash
sudo apt install -y clang llvm make gcc iproute2 bpftool linux-tools-common linux-tools-generic tcpdump
```

Depending on distro/package availability, `bpftool` may need to be installed from kernel-specific packages.

---

## 5. Attachment Point

### 5.1 Initial Attachment Point

For Phase 1, attach the TC eBPF program to the **host-side veth interface of the client container**.

This is the preferred first attachment point because:

- traffic originates from the client container,
- outgoing packets contain the original inner container flow,
- the 5-tuple is easy to parse,
- we avoid VXLAN outer-header parsing initially,
- it is easy to correlate observed flows with generated `netperf` traffic.

### 5.2 Finding the Host-Side veth Interface

On the client host, get the client container PID:

```bash
CLIENT_CONTAINER=netperf-client
PID=$(docker inspect -f '{{.State.Pid}}' "$CLIENT_CONTAINER")
echo "$PID"
```

Inspect interfaces inside the container network namespace:

```bash
sudo nsenter -t "$PID" -n ip link
```

You may see something like:

```text
2: eth0@if123: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
```

The `if123` part points to the peer ifindex on the host.

Find the host-side veth:

```bash
ip link | grep -B1 "if123"
```

Example output:

```text
123: vethabcd123@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
```

In this example, attach to:

```text
vethabcd123
```

### 5.3 Verify the Interface with tcpdump

Before attaching eBPF, verify that traffic is visible:

```bash
sudo tcpdump -ni vethabcd123 tcp or udp
```

In another terminal, run a short test:

```bash
docker exec netperf-client netperf -H <server-container-ip> -t TCP_RR -l 5 -- -r 64,64
```

Pass condition:

- tcpdump shows packets on the selected veth.

---

## 6. Supported Packet Types

Phase 1 should intentionally support only a narrow set of packet types.

### 6.1 Supported

- Ethernet
- IPv4
- TCP
- UDP

### 6.2 Unsupported for Now

- IPv6
- VLAN-tagged packets
- fragmented IPv4 packets
- ICMP
- non-TCP/UDP protocols
- VXLAN outer-header parsing
- advanced GSO/GRO edge cases

Unsupported packets must be passed normally with `TC_ACT_OK`.

They should increment an unsupported/error counter where appropriate.

---

## 7. eBPF Maps

The eBPF program should use three logical map groups:

1. `flow_stats`
2. `hot_flows`
3. `global_counters`

---

## 7.1 Flow Key

Use a 5-tuple flow key.

```c
struct flow_key {
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u8  proto;
    __u8  pad1;
    __u16 pad2;
};
```

Notes:

- IPv4 addresses should remain in network byte order unless userspace explicitly converts them.
- Ports should remain in network byte order or be consistently converted. Choose one convention and document it.
- Padding is explicit to avoid layout mismatch between eBPF and userspace.

---

## 7.2 Flow Statistics Map

The `flow_stats` map stores telemetry for observed flows.

### Key

```c
struct flow_key
```

### Value

```c
struct flow_stats {
    __u64 first_seen_ns;
    __u64 last_seen_ns;
    __u64 packets;
    __u64 sampled_packets;
    __u64 bytes;
};
```

### Suggested Map Type

```c
BPF_MAP_TYPE_LRU_HASH
```

### Suggested Initial Capacity

```text
65536 entries
```

Rationale:

- LRU prevents unbounded growth during cold-flow storms.
- 65536 entries are enough for early testing.
- Capacity can be made configurable later.

---

## 7.3 Hot Flow Map

Even though Phase 1 does not implement Top-K selection yet, create a `hot_flows` map now so that the eBPF program can test the lookup path.

### Key

```c
struct flow_key
```

### Value

```c
struct hot_flow_value {
    __u64 estimated_pps;
    __u64 updated_ns;
};
```

### Suggested Map Type

```c
BPF_MAP_TYPE_LRU_HASH
```

### Suggested Initial Capacity

```text
4096 entries
```

In Phase 1, the map may remain empty most of the time. Later, it will be maintained by the userspace Top-K controller.

The eBPF program should do:

```text
if flow exists in hot_flows:
    increment HOT_PACKETS
else:
    increment FALLBACK_PACKETS
```

This creates the future fast-path/fallback-path classification interface without changing packet behavior.

---

## 7.4 Global Counters Map

Use a global counter map for debugging and validation.

For Phase 1, a normal array map is acceptable. Later, if contention becomes visible, switch to a per-CPU array map.

### Suggested Counter IDs

```c
enum counter_id {
    CNT_TOTAL_PACKETS = 0,
    CNT_PARSED_IPV4,
    CNT_PARSED_TCP,
    CNT_PARSED_UDP,
    CNT_UNSUPPORTED_ETH,
    CNT_UNSUPPORTED_IP,
    CNT_FRAGMENTED_IP,
    CNT_FLOW_NEW,
    CNT_FLOW_SEEN,
    CNT_HOT_PACKETS,
    CNT_FALLBACK_PACKETS,
    CNT_SAMPLE_SKIPPED,
    CNT_PARSE_ERROR,
    CNT_MAX
};
```

### Suggested Map Type

```c
BPF_MAP_TYPE_ARRAY
```

### Key

```c
__u32 counter_id
```

### Value

```c
__u64 counter_value
```

---

## 8. eBPF Program Behavior

For every packet, the TC eBPF program should:

1. increment `CNT_TOTAL_PACKETS`,
2. read `data` and `data_end`,
3. parse Ethernet header,
4. reject unsupported EtherTypes,
5. parse IPv4 header,
6. reject fragmented packets,
7. parse TCP or UDP header,
8. extract `flow_key`,
9. optionally sample the packet,
10. update `flow_stats`,
11. check `hot_flows`,
12. increment hot/fallback counters,
13. return `TC_ACT_OK`.

Pseudo-code:

```c
SEC("tc")
int flow_classifier(struct __sk_buff *skb)
{
    increment_counter(CNT_TOTAL_PACKETS);

    struct flow_key key = {};
    __u64 bytes = skb->len;

    int ret = parse_packet(skb, &key);
    if (ret < 0) {
        return TC_ACT_OK;
    }

    if (sampling_enabled()) {
        if (should_skip_sample()) {
            increment_counter(CNT_SAMPLE_SKIPPED);
            return TC_ACT_OK;
        }
    }

    update_flow_stats(&key, bytes);

    if (bpf_map_lookup_elem(&hot_flows, &key)) {
        increment_counter(CNT_HOT_PACKETS);
    } else {
        increment_counter(CNT_FALLBACK_PACKETS);
    }

    return TC_ACT_OK;
}
```

---

## 9. Packet Sampling

### 9.1 Initial Mode

For the first version, disable sampling:

```text
sampling = 1/1
```

This makes debugging easier.

### 9.2 Later Mode

After the parser and maps work, enable approximate sampling:

```text
sampling = 1/8
```

Example logic:

```c
if ((bpf_get_prandom_u32() & 7) != 0) {
    increment_counter(CNT_SAMPLE_SKIPPED);
    return TC_ACT_OK;
}
```

Estimated packet count:

```text
estimated_packets = sampled_packets * 8
```

Accuracy requirement:

```text
±20% is acceptable for hot/cold classification
```

Sampling is mainly meant to reduce per-packet map update overhead.

---

## 10. Project Structure

Suggested repository layout:

```text
phase1-ebpf/
├── ebpf/
│   ├── flow_classifier.bpf.c
│   └── common.h
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

---

## 11. Build Instructions

Create a build directory:

```bash
mkdir -p build
```

Compile the eBPF object:

```bash
clang -O2 -g -target bpf \
  -D__TARGET_ARCH_x86 \
  -c ebpf/flow_classifier.bpf.c \
  -o build/flow_classifier.bpf.o
```

If the program requires kernel headers, ensure the necessary headers are installed.

On Ubuntu-like systems:

```bash
sudo apt install -y linux-headers-$(uname -r)
```

For kernel 5.4, keep code conservative:

- avoid unnecessary loops,
- use explicit bounds checks,
- avoid newer helper functions unless verified available,
- keep stack usage small.

---

## 12. TC Attachment Scripts

### 12.1 Attach Script

`scripts/attach.sh` should accept an interface name:

```bash
#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:?Usage: $0 <iface>}"
OBJ="${2:-build/flow_classifier.bpf.o}"
SEC="${3:-tc}"

sudo tc qdisc add dev "$IFACE" clsact 2>/dev/null || true
sudo tc filter replace dev "$IFACE" ingress bpf da obj "$OBJ" sec "$SEC"

echo "Attached $OBJ section $SEC to $IFACE ingress"
```

### 12.2 Detach Script

`scripts/detach.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:?Usage: $0 <iface>}"

sudo tc filter del dev "$IFACE" ingress 2>/dev/null || true
sudo tc qdisc del dev "$IFACE" clsact 2>/dev/null || true

echo "Detached TC filters from $IFACE"
```

### 12.3 Show TC State

```bash
sudo tc filter show dev <iface> ingress
sudo tc qdisc show dev <iface>
```

---

## 13. Map and Program Debugging

Useful commands:

```bash
sudo bpftool prog show
sudo bpftool map show
sudo tc filter show dev <iface> ingress
```

If maps are pinned under `/sys/fs/bpf`, dump them with:

```bash
sudo bpftool map dump pinned /sys/fs/bpf/<map-name>
```

If maps are not pinned, inspect map IDs:

```bash
sudo bpftool map show
```

Then dump by ID:

```bash
sudo bpftool map dump id <map-id>
```

For debugging, `bpf_printk()` may be used sparingly, but do not rely on it for benchmark runs.

Trace output:

```bash
sudo cat /sys/kernel/debug/tracing/trace_pipe
```

---

## 14. Userspace Flow Dump Tool

A minimal userspace flow dump tool should:

1. open the `flow_stats` map,
2. iterate over all keys,
3. convert IP addresses and ports to readable format,
4. print packet count, sampled count, bytes, age, and last-seen time.

Example output target:

```text
src_ip        src_port  dst_ip        dst_port  proto  packets  sampled  bytes   age_ms  last_seen_ms
10.0.2.5      49122     10.0.1.3      12865     TCP    18234    18234    123456  30000   12
10.0.2.5      50211     10.0.1.3      12865     TCP    12       12       1024    80      70
```

This tool can be written in Python for early development or C/libbpf for a more robust implementation.

---

# 15. Test Plan

## Test 0: Environment Sanity

Run on the client host:

```bash
uname -r
tc -V
bpftool version
clang --version
```

Check Docker containers:

```bash
docker ps
```

Check benchmark connectivity:

```bash
docker exec netperf-client netperf -H <server-container-ip> -t TCP_RR -l 5 -- -r 64,64
```

Pass condition:

- command completes successfully,
- no packet loss or connection failure,
- containers can communicate.

---

## Test 1: Find Correct veth Interface

Run:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' netperf-client)
sudo nsenter -t "$PID" -n ip link
```

Find `eth0@ifXYZ`, then:

```bash
ip link | grep -B1 "ifXYZ"
```

Validate with tcpdump:

```bash
sudo tcpdump -ni <veth> tcp or udp
```

Generate traffic:

```bash
docker exec netperf-client netperf -H <server-container-ip> -t TCP_RR -l 5 -- -r 64,64
```

Pass condition:

- tcpdump shows the test traffic.

---

## Test 2: Attach and Detach

Attach:

```bash
./scripts/attach.sh <veth>
```

Verify:

```bash
sudo tc filter show dev <veth> ingress
```

Detach:

```bash
./scripts/detach.sh <veth>
```

Verify again:

```bash
sudo tc filter show dev <veth> ingress
```

Pass condition:

- filter appears after attach,
- filter disappears after detach,
- container networking continues working.

---

## Test 3: Passive No-Traffic Counter Test

Attach the eBPF program.

Do not run benchmark traffic for a few seconds.

Dump counters.

Expected:

- total packets may be low,
- parser error counters should not grow unexpectedly,
- no networking disruption.

Check connectivity:

```bash
docker exec netperf-client ping -c 3 <server-container-ip>
```

Pass condition:

- ping works,
- no drops caused by the eBPF program.

---

## Test 4: Basic TCP_RR Flow Detection

Run one persistent request-response flow:

```bash
docker exec netperf-client netperf -H <server-container-ip> -t TCP_RR -l 10 -- -r 64,64
```

Dump the `flow_stats` map.

Expected:

- at least one TCP flow appears,
- source/destination IPs match the containers,
- destination port matches `netserver`,
- packet count is nonzero.

Pass condition:

- `flow_stats` contains the TCP_RR flow with a meaningful packet count.

---

## Test 5: Basic TCP_CRR Cold-Flow Detection

Run short-lived connection traffic:

```bash
docker exec netperf-client netperf -H <server-container-ip> -t TCP_CRR -l 10 -- -r 64,64
```

Dump the `flow_stats` map.

Expected:

- many TCP flows appear,
- each flow has relatively low packet count,
- the number of distinct 5-tuples is much higher than with TCP_RR.

Pass condition:

- TCP_CRR creates many more distinct flows than TCP_RR.

---

## Test 6: Hot vs Cold Comparison

Run mixed traffic:

```bash
for i in $(seq 1 10); do
  docker exec netperf-client netperf -H <server-container-ip> -t TCP_RR -l 30 -- -r 64,64 &
done

sleep 5

for i in $(seq 1 10); do
  docker exec netperf-client netperf -H <server-container-ip> -t TCP_CRR -l 20 -- -r 64,64 &
done

wait
```

Dump `flow_stats`.

Expected:

- TCP_RR flows should be among the highest packet-count flows,
- TCP_CRR should create many low-count flows,
- the difference between hot and cold behavior should be visible.

Pass condition:

- top flows by packet count correspond to the long-lived TCP_RR workers.

---

## Test 7: Sampling Correctness

Run the same TCP_RR workload twice:

1. sampling disabled,
2. sampling enabled at 1/8.

Expected:

```text
sampled_packets * 8 ≈ unsampled_packets
```

Accuracy requirement:

```text
within ±20% for high-rate flows
```

Pass condition:

- sampled estimate is close enough for hot-flow detection.

---

## Test 8: LRU Map Capacity Behavior

Temporarily reduce `flow_stats.max_entries` to a small value:

```text
128 entries
```

Run a cold-flow storm:

```bash
for i in $(seq 1 64); do
  docker exec netperf-client netperf -H <server-container-ip> -t TCP_CRR -l 30 -- -r 64,64 &
done
wait
```

Expected:

- map does not grow beyond capacity,
- old entries are evicted by LRU behavior,
- networking remains functional.

Pass condition:

- map remains bounded,
- eBPF program continues working,
- no kernel/network instability.

---

## Test 9: Manual Hot-Flow Map Test

Manually insert a known flow into `hot_flows` using a small tool or `bpftool`.

Then run traffic for that flow again.

Expected:

- packets matching that flow increment `CNT_HOT_PACKETS`,
- other packets increment `CNT_FALLBACK_PACKETS`.

Pass condition:

- hot-flow map lookup path works.

This test prepares the code for Phase 2, where userspace will maintain `hot_flows` automatically.

---

## Test 10: Overhead Sanity Test

Run the benchmark without eBPF attached:

```bash
docker exec netperf-client netperf -H <server-container-ip> -t TCP_RR -l 30 -- -r 64,64
```

Then attach eBPF and run the same benchmark again.

Compare:

- transaction rate,
- CPU usage,
- packet counters.

Pass condition for Phase 1:

```text
Debug version: less than roughly 10% overhead
Sampled version: target less than roughly 3-5% overhead
```

These are development targets, not strict final thesis claims.

---

# 16. Expected Outputs at End of Phase 1

At the end of Phase 1, we should be able to produce:

- total observed packets,
- parsed IPv4 packet count,
- parsed TCP packet count,
- parsed UDP packet count,
- unsupported packet counters,
- number of unique tracked flows,
- top flows by packet count,
- flow age and last-seen timestamps,
- hot/fallback packet counters,
- sampling behavior validation,
- evidence that TCP_RR creates hot-flow-like entries,
- evidence that TCP_CRR creates many cold-flow-like entries.

---

# 17. Risks and Mitigations

## Risk: Wrong Interface Attachment

Mitigation:

- verify with `tcpdump` before attaching,
- use container PID and `nsenter` to find the correct veth,
- start with only one container interface.

## Risk: Verifier Rejection

Mitigation:

- add bounds checks before every header access,
- keep parser simple,
- avoid complex loops,
- keep stack usage small,
- compile with debug info and inspect verifier logs.

## Risk: Map Update Overhead

Mitigation:

- start with exact counting,
- add sampling after correctness is proven,
- use LRU maps to bound memory usage,
- consider per-CPU maps later only if needed.

## Risk: Cold Flows Fill the Map

Mitigation:

- use `BPF_MAP_TYPE_LRU_HASH`,
- keep map size configurable,
- add userspace cleanup in Phase 2.

## Risk: Userspace Decodes Flow Keys Incorrectly

Mitigation:

- keep shared structs in `common.h`,
- use explicit padding,
- initially print raw hex values,
- then add human-readable IP/port formatting.

## Risk: Telemetry Changes Performance Too Much

Mitigation:

- avoid `bpf_printk()` in benchmark runs,
- keep counters minimal,
- use sampling,
- compare benchmark results with and without eBPF attached.

---

# 18. Recommended Implementation Order for an AI Agent

An AI coding agent should implement this phase in small steps.

## Step 1: Create Project Skeleton

Create:

```text
phase1-ebpf/
├── ebpf/
├── scripts/
├── user/
└── README.md
```

## Step 2: Define Shared Structures

Create `ebpf/common.h` with:

- `struct flow_key`,
- `struct flow_stats`,
- `struct hot_flow_value`,
- counter enum.

## Step 3: Create Minimal eBPF Program

Create `ebpf/flow_classifier.bpf.c` that:

- defines maps,
- increments `CNT_TOTAL_PACKETS`,
- returns `TC_ACT_OK`.

## Step 4: Add Build Script

Create `scripts/build.sh` that compiles the eBPF object.

## Step 5: Add Attach/Detach Scripts

Create:

- `scripts/attach.sh`,
- `scripts/detach.sh`,
- `scripts/show_tc.sh`.

## Step 6: Test Minimal Attach

Attach to a veth and verify:

```bash
sudo tc filter show dev <veth> ingress
```

## Step 7: Add Ethernet + IPv4 Parsing

Add safe bounds-checked parsing.

Update counters:

- parsed IPv4,
- unsupported EtherType,
- parse errors.

## Step 8: Add TCP/UDP Parsing

Extract:

- source IP,
- destination IP,
- source port,
- destination port,
- protocol.

Update TCP/UDP counters.

## Step 9: Add Flow Statistics Map Update

Update or create `flow_stats` entries.

Track:

- first seen,
- last seen,
- packets,
- bytes.

## Step 10: Add Basic Dump Tool

Create `user/dump_flows.py` or `user/dump_flows.c`.

It should print tracked flows in readable form.

## Step 11: Add Sampling Option

Add compile-time constant or map-based setting for sampling.

Start with disabled sampling.

Then test 1/8 sampling.

## Step 12: Add `hot_flows` Lookup

Add lookup in eBPF:

- if found: increment `CNT_HOT_PACKETS`,
- else: increment `CNT_FALLBACK_PACKETS`.

Do not change packet behavior.

## Step 13: Run Full Phase 1 Test Plan

Run Tests 0 through 10.

## Step 14: Document Results

Create a short result note with:

- which interface was used,
- kernel version,
- Docker/container setup,
- test outputs,
- map dump examples,
- overhead observations,
- known limitations.

---

# 19. Definition of Done

Phase 1 is complete when all of the following are true:

- the eBPF program builds successfully,
- it attaches and detaches cleanly at TC ingress,
- container networking continues working,
- TCP_RR traffic creates a small number of high-count flows,
- TCP_CRR traffic creates many low-count flows,
- flow map contents can be dumped and interpreted,
- global counters reflect expected packet types,
- sampling works approximately correctly,
- `hot_flows` lookup path works at least with manual insertion,
- passive telemetry overhead is acceptable for development,
- all behavior is non-invasive and packets continue normally.

Once Phase 1 is complete, proceed to Phase 2: userspace Top-K hot-flow controller.
