# Hybrid overlay eBPF benchmark

Reproducible harness for the cache-accelerated, multi-core-aware container
overlay datapath evaluated in the dissertation. Compares four configurations
on a two-node Kubernetes + Antrea cluster: **baseline**, **ONCache**,
**Falcon-style multi-core fallback**, and the **hybrid** (ONCache + Falcon
fallback).

---

> # :warning: Hardware requirement
>
> **This benchmark MUST be run on two physical hosts connected by a
> dedicated 100 Gbit/s direct Layer-2 link** (point-to-point or a single
> isolated VLAN, no intermediate routers, no shared production fabric).
>
> Any other setup — virtualised hosts, loopback, slower NICs, shared
> switches, or hosts behind routed segments — will produce numbers that
> are **not comparable** to the published results in the thesis and may
> mask or invert the differences between modes.

---

## Running the benchmark

```bash
cd oncache-k8s
./scripts/run_latency_benchmark.sh \
  ./conf/oncache_k8s_setup.conf \
  ./conf/latency_benchmark.conf
```

This executes, in order, on the same cluster and pod placement:

1. `baseline` — stock Antrea overlay
2. `oncache` — upstream ONCache cache fast path
3. `falcon` — Falcon-style multi-core fallback (RPS/XPS spread across all
   CPUs on the overlay datapath; no ONCache)
4. `hybrid` — ONCache fast path **plus** the Falcon-style fallback

For each mode the harness runs both **hot** flows (`TCP_RR`, persistent TCP)
and **cold** flows (`TCP_CRR`, new TCP per transaction) across several worker
counts, with repeated trials.

### Output

Results are written to a timestamped directory under
`oncache-k8s/results/k8s-latency/<RUN_ID>/`, with per-worker raw logs and
an aggregated `summary.csv`:

```
run_id,mode,flow_type,netperf_test,workers,repeat,ok,failed,
total_txn_s,avg_latency_ms,p50_latency_ms,p95_latency_ms,p99_latency_ms
```

Each `(mode, flow_type)` group in this CSV maps directly to a cell in the
main results table of the dissertation.

### Useful variants

```bash
# Falcon-only (baseline vs Falcon fallback, no ONCache, no hybrid):
./scripts/run_latency_benchmark_falcon_only.sh \
  ./conf/oncache_k8s_setup.conf ./conf/latency_benchmark.conf

# Overlay-stress matrix (low MTU + many NetworkPolicies):
./scripts/run_latency_benchmark_overlay_stress.sh \
  ./conf/oncache_k8s_setup.conf ./conf/latency_benchmark.conf

# CPU-stress matrix (stress-ng on both nodes during the run):
./scripts/run_latency_benchmark_cpu_stress.sh \
  ./conf/oncache_k8s_setup.conf ./conf/latency_benchmark.conf

# Custom mode subset:
BENCHMARK_MODES="baseline hybrid" \
  ./scripts/run_latency_benchmark.sh \
  ./conf/oncache_k8s_setup.conf ./conf/latency_benchmark.conf
```

## Layout

| Directory | Purpose |
|-----------|---------|
| `oncache-k8s/` | Kubernetes + Antrea harness and the main benchmark runner |
| `oncache-falcon-hybrid/` | Falcon-style multi-core fallback scripts and the hybrid composition |
| `oncache-benchmark/` | Standalone Docker mixed-workload harness (ipvlan) |
| `oncache-docker/` | Legacy single-host Docker baseline |
| `phase1-ebpf/` | Earlier passive eBPF telemetry prototype |
